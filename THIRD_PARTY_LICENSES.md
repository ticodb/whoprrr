# Third-party licenses

Whoprrr is MIT licensed (see `LICENSE`). This file lists the only third-party source code that ships inside the project, with its
license text. Credits for work Whoprrr learned from but does not contain are in [ACKNOWLEDGMENTS.md](ACKNOWLEDGMENTS.md).

## m1ddc

- Used for: the DDC/CI transport that talks to external displays on Apple Silicon.
- Where: `Sources/CDDC/upstream/` (copied unmodified; see `PROVENANCE.md` there for the exact commit).
- Project: https://github.com/waydabber/m1ddc
- License: MIT

```
MIT License

Copyright (c) 2021 waydabber

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

## Not bundled

Whoprrr links only Apple system frameworks and the system SQLite library. It does not bundle, and is not a derivative of,
Audio Unit or VST plugins, fonts, or any GPL-licensed code. Audio Unit plugins you add are loaded from your own Mac and keep their
own licenses.
