# Gemini 原生 Interactions 接入

设置 → Google Gemini，填写 `https://generativelanguage.googleapis.com/v1beta/interactions`、有效的模型 ID 和 Gemini API Key。
旧的 `/v1beta/openai`、基础 `/v1beta` 和误拼接的 `/interactions/chat/completions` 地址均在请求时转换为 `/interactions`。不改变其他 OpenAI 兼容服务。

实现位于 `lib/src/gemini_interactions.dart`，作为现有客户端的 Gemini 专用协议适配。聊天、建议回复、记忆整理均明确按服务类型路由。

- 使用 `x-goog-api-key` 请求头；系统提示词使用 `system_instruction`。
- 按当前官方 SDK 的原生 `input` 步骤格式发送 `user_input` / `model_output`，接收 `steps`；同时兼容旧响应的 `outputs`。
- 普通回复使用 SSE `step.delta` 文本增量与 `interaction.completed`，也接受旧 `content.delta` 文本事件。思考内容不作为角色台词播放；中途断流报告错误。
- Agent 使用非流式工具决策、原生 `function_call` / `function_result`，完整保留服务端返回的步骤和思考签名。最多四轮，每轮最多三个工具；权限沿用原来的按需请求流程。
- 使用 `store: false`，由应用维护历史，不依赖远端 interaction ID。
- 图片使用 `image`，PDF 使用 `document`，以 Base64 和 `mime_type` 传入；文本文件转为文本内容，其他文档需先转换。
- 密钥保留在现有安全存储中，不发送 OpenAI 的推理和输出倍率参数。

依据：[官方指南](https://ai.google.dev/gemini-api/docs/interactions)、[Google 官方 Python SDK 原生类型](https://github.com/googleapis/python-genai/tree/main/google/genai/_gaos/types/interactions)。

自动测试使用模拟响应；实际模型权限、配额及线上协议仍需使用有效密钥验证。模型名称保持用户填写值，不自动换成另一个模型。
