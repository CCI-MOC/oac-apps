function headerNotEmpty(parsed) {
  return [(parsed.header || "").trim().length > 0, "subject may not be empty"];
}

function bodyMaxLineLength(parsed, _when, maxLength) {
  let inFence = false;
  const violations = (parsed.body || "").split("\n").filter((line) => {
    // Lines inside a fenced code block (```...```) are literal content,
    // e.g. a YAML snippet or shell command quoted verbatim in the commit
    // body. Rewrapping those would corrupt their meaning, so they're
    // exempt regardless of whether any individual word is long.
    if (/^ *```/.test(line)) {
      inFence = !inFence;
      return false;
    }
    if (inFence) {
      return false;
    }

    if (line.length <= maxLength) {
      return false;
    }
    // Lines indented by 4+ spaces are treated as a literal/code block
    // (the usual Markdown convention), e.g. a YAML snippet or shell
    // command quoted verbatim in the commit body. Rewrapping those
    // would corrupt their meaning, so they're exempt regardless of
    // whether any individual word is long.
    if (/^ {4,}\S/.test(line)) {
      return false;
    }
    const words = line.trim().split(/\s+/);
    const unbreakable = words.some((word) => word.length > maxLength);
    return !unbreakable;
  });

  return [
    violations.length === 0,
    `body's lines must be wrapped to ${maxLength} characters or less, unless unbreakable`,
  ];
}

module.exports = {
  plugins: [
    {
      rules: {
        "header-not-empty": headerNotEmpty,
        "body-max-line-length-unless-unbreakable": bodyMaxLineLength,
      },
    },
  ],
  rules: {
    "header-max-length": [2, "always", 60],
    "header-not-empty": [2, "always"],
    "body-leading-blank": [2, "always"],
    "body-empty": [2, "never"],
    "body-max-line-length-unless-unbreakable": [2, "always", 75],
  },
};
