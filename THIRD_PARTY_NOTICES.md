# Third-party notices

## Documentation fonts

The guides self-host Inter and IBM Plex Mono under the SIL Open Font License
1.1. Their copyright notices and complete licenses are distributed alongside
the font files in `docs/assets/fonts/Inter-LICENSE.txt` and
`docs/assets/fonts/Plex-LICENSE.txt`.

- Inter: https://github.com/rsms/inter, revision
  `353b61b9f4430d5f420d56605a6e7993e0941470`.
- IBM Plex: https://github.com/IBM/plex, revision
  `71f558992315a12ca1f06a2215d57962a1992162`.

The static Inter regular, semibold, bold, and italic files were obtained from
`https://rubyonrails.org/assets/fonts/Inter-*.woff2?v=4.0`, the same URLs used
by Rails Guides, on October 23, 2026. They retain the Inter license above.
IBM Plex Mono Text uses the exact file served at
`https://rubyonrails.org/assets/fonts/IBMPlexMono-Text.woff2`, obtained on
October 23, 2026, under the IBM Plex license above.
Calibre is loaded from the Rails-hosted font URLs declared in
`docs/assets/fonts.css`; Calibre font files are not distributed in this repository.

The documentation stylesheet is an original implementation of the visual
reference requested by the project: https://guides.rubyonrails.org/index.html.

## Protocol data

`lib/object_framework/http2/hpack_tables.rb` contains the static header table
and Huffman code table from RFC 7541, Appendices A and B:
https://www.rfc-editor.org/rfc/rfc7541.html

Copyright (c) 2015 IETF Trust and the persons identified as the document authors.
All rights reserved.

Redistribution and use in source and binary forms, with or without
modification, are permitted provided that the following conditions are met:

1. Redistributions of source code must retain the above copyright notice,
   this list of conditions and the following disclaimer.
2. Redistributions in binary form must reproduce the above copyright notice,
   this list of conditions and the following disclaimer in the documentation
   and/or other materials provided with the distribution.

THIS SOFTWARE IS PROVIDED BY THE COPYRIGHT HOLDERS AND CONTRIBUTORS "AS IS"
AND ANY EXPRESS OR IMPLIED WARRANTIES, INCLUDING, BUT NOT LIMITED TO, THE
IMPLIED WARRANTIES OF MERCHANTABILITY AND FITNESS FOR A PARTICULAR PURPOSE
ARE DISCLAIMED. IN NO EVENT SHALL THE COPYRIGHT HOLDER OR CONTRIBUTORS BE
LIABLE FOR ANY DIRECT, INDIRECT, INCIDENTAL, SPECIAL, EXEMPLARY, OR
CONSEQUENTIAL DAMAGES (INCLUDING, BUT NOT LIMITED TO, PROCUREMENT OF SUBSTITUTE
GOODS OR SERVICES; LOSS OF USE, DATA, OR PROFITS; OR BUSINESS INTERRUPTION)
HOWEVER CAUSED AND ON ANY THEORY OF LIABILITY, WHETHER IN CONTRACT, STRICT
LIABILITY, OR TORT (INCLUDING NEGLIGENCE OR OTHERWISE) ARISING IN ANY WAY OUT
OF THE USE OF THIS SOFTWARE, EVEN IF ADVISED OF THE POSSIBILITY OF SUCH DAMAGE.
