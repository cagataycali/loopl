var tool = {
  name: "reverse_string",                        // 1-64 chars: letters, digits, _ -
  description: "Reverses the given text.",       // tells the model when to use it
  inputSchema: { type: "object", properties: { text: { type: "string" } }, required: ["text"] },
  call(args) {                                   // may return a string, an object, or a Promise
    if (typeof args.text !== "string") throw new Error("text is required");
    return args.text.split("").reverse().join("");
  }
};
// Bridge: loopl.call("calculator", {expression: "2+2"}) runs another mounted tool (returns its text);
// loopl.http(url, {method, headers, body}) → {status, body}; loopl.log("…"). No eval of fetched code.
