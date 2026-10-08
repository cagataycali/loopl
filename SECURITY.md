# Security

loopl runs models on the device and collects no data ([privacy](https://loopl.dev/privacy/)). The surface that
matters is the agent's tools: approvals, the `http` tool, the Hugging Face token, and what reaches the model.

If you find a way for a tool to act without the approval the app promised, for a secret to reach the transcript,
a log or disk, or for the Bearer token to leave `huggingface.co`, please report it privately:

- GitHub: [report a vulnerability](https://github.com/cagataycali/loopl/security/advisories/new)

You will get an answer within a week. Please do not open a public issue for a security report.
