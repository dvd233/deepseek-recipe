use super::{decode_handler, ApiFormat, DecodeFinishReason, DecodeRequest};
use axum::Json;
use serde_json::{json, Value};

const PATCH_INPUT: &str = "*** Begin Patch\n*** Add File: hello.txt\n+Hello, 世界 😀\n*** End Patch";

fn model_output() -> String {
    format!(
        "<｜DSML｜ calls>\n<｜DSML｜ invoke name=\"apply_patch\">\n<｜DSML｜ parameter name=\"input\" string=\"true\">{PATCH_INPUT}</｜DSML｜ parameter>\n</｜DSML｜ invoke>\n</｜DSML｜ calls><｜end▁of▁sentence｜>"
    )
}

fn parameters() -> Value {
    json!({"type": "object", "properties": {"input": {"type": "string"}}, "required": ["input"]})
}

async fn decode(format: ApiFormat, body: Value) -> Value {
    let result = decode_handler(Json(DecodeRequest {
        format,
        body,
        output: model_output(),
        finish_reason: DecodeFinishReason::Stop,
    }))
    .await;
    match result {
        Ok(Json(payload)) => payload.response,
        Err((status, _)) => panic!("demo handler unexpectedly rejected fixture with {status}"),
    }
}

fn named_output(response: &Value) -> &Value {
    response["output"]
        .as_array()
        .expect("Responses output must be an array")
        .iter()
        .find(|item| item["name"] == "apply_patch")
        .expect("the native demo handler must produce the declared tool call")
}

#[tokio::test]
async fn responses_custom_tool_keeps_native_input() {
    let response = decode(
        ApiFormat::Responses,
        json!({
            "input": "Create hello.txt",
            "tools": [{"type": "custom", "name": "apply_patch"}]
        }),
    )
    .await;
    eprintln!("native-demo-response: {response}");
    let call = named_output(&response);
    let actual_type = call["type"].as_str().expect("tool call type must be a string");
    assert_eq!(actual_type, "custom_tool_call", "CUSTOM_TOOL_TYPE_MISMATCH: demo must retain the Responses custom tool declaration");
    assert_eq!(call["input"], PATCH_INPUT);
    assert!(call.get("arguments").is_none());
}

#[tokio::test]
async fn control_responses_function_with_same_name_keeps_arguments() {
    let response = decode(
        ApiFormat::Responses,
        json!({
            "input": "Create hello.txt",
            "tools": [{"type": "function", "name": "apply_patch", "parameters": parameters()}]
        }),
    )
    .await;
    let call = named_output(&response);
    assert_eq!(call["type"], "function_call");
    let arguments: Value = serde_json::from_str(call["arguments"].as_str().unwrap()).unwrap();
    assert_eq!(arguments["input"], PATCH_INPUT);
    assert!(call.get("input").is_none());
}

#[tokio::test]
async fn control_chat_completions_keeps_function_arguments() {
    let response = decode(
        ApiFormat::ChatCompletions,
        json!({
            "messages": [{"role": "user", "content": "Create hello.txt"}],
            "tools": [{"type": "function", "function": {"name": "apply_patch", "parameters": parameters()}}]
        }),
    )
    .await;
    let call = &response["choices"][0]["message"]["tool_calls"][0];
    assert_eq!(call["type"], "function");
    assert_eq!(call["function"]["name"], "apply_patch");
    let arguments: Value = serde_json::from_str(call["function"]["arguments"].as_str().unwrap()).unwrap();
    assert_eq!(arguments["input"], PATCH_INPUT);
}

#[tokio::test]
async fn control_messages_keeps_tool_input() {
    let response = decode(
        ApiFormat::Messages,
        json!({
            "messages": [{"role": "user", "content": "Create hello.txt"}],
            "tools": [{"name": "apply_patch", "input_schema": parameters()}]
        }),
    )
    .await;
    let call = response["content"]
        .as_array()
        .unwrap()
        .iter()
        .find(|item| item["type"] == "tool_use")
        .expect("Messages tool-use item");
    assert_eq!(call["name"], "apply_patch");
    assert_eq!(call["input"]["input"], PATCH_INPUT);
}
