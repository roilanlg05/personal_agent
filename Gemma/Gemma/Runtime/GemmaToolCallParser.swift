import Foundation

/// Branch A (mlx-lm server normalizes to OpenAI `tool_calls`): the visible answer is already
/// the clean `message.content` and tool calls arrive in `message.tool_calls`, so there is no
/// inline tool-call/thought syntax to strip from the text. `strip` is therefore a no-op.
/// (Branch B — native Gemma `<|tool_call>…` text — would replace this with a real parser.)
enum GemmaToolCallParser {
    static func strip(_ s: String) -> String { s }
}
