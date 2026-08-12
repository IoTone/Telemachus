# Acknowledgments

Telemachus is MIT-licensed and built from the maintainer's own code. This file
credits third-party work whose **patterns or designs** are reflected in that
code, so their permissive-license attribution requirements are honored even
where no source is copied verbatim.

If you believe something here is mis-attributed or missing, please open an issue
— it will be corrected promptly.

---

## Adapted patterns

- **[opencode](https://github.com/anomalyco/opencode)** — open-source AI coding
  agent (originally [opencode-ai/opencode](https://github.com/opencode-ai/opencode)).
  Copyright © the opencode authors. **MIT License.** The agent-loop and
  tool-execution *patterns* in `racket/domain/agent/loop.rkt` and
  `racket/domain/tools/convert.rkt` descend from opencode (by way of the
  predecessor project's agent core). No opencode source is included; this credit
  satisfies the MIT attribution requirement for the reflected design.

The MIT License requires preserving the original copyright and permission
notice. The standard MIT text, applicable to the opencode-derived patterns above:

```
MIT License

Copyright (c) the opencode authors

Permission is hereby granted, free of charge, to any person obtaining a copy
of this software and associated documentation files (the "Software"), to deal
in the Software without restriction, including without limitation the rights
to use, copy, modify, merge, publish, distribute, sublicense, and/or sell
copies of the Software, and to permit persons to whom the Software is
furnished to do so, subject to the following conditions:

The above copyright notice and this permission notice shall be included in all
copies or substantial portions of the Software.

THE SOFTWARE IS PROVIDED "AS IS", WITHOUT WARRANTY OF ANY KIND, EXPRESS OR
IMPLIED, INCLUDING BUT NOT LIMITED TO THE WARRANTIES OF MERCHANTABILITY,
FITNESS FOR A PARTICULAR PURPOSE AND NONINFRINGEMENT. IN NO EVENT SHALL THE
AUTHORS OR COPYRIGHT HOLDERS BE LIABLE FOR ANY CLAIM, DAMAGES OR OTHER
LIABILITY, WHETHER IN AN ACTION OF CONTRACT, TORT OR OTHERWISE, ARISING FROM,
OUT OF OR IN CONNECTION WITH THE SOFTWARE OR THE USE OR OTHER DEALINGS IN THE
SOFTWARE.
```

---

## Future additions

As more subsystems land, credit their design lineage here (e.g. any research
pipeline reflecting **Tongyi DeepResearch** (Apache-2.0), or hardware-fit logic
reflecting **llmfit** (MIT)). Bundled runtime dependencies and services get
their own entries when they are actually shipped.
