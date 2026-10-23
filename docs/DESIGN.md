# Guides design and editorial brief

Readers are Ruby developers building applications from collaborating objects.
The site works as a course and as a reference book. Each guide connects a
runnable example to the responsibility, invariant, and tradeoff behind it.

The user requested the visual style of
[the Rails Guides index](https://guides.rubyonrails.org/index.html), as well as
its progressive teaching and explicit examples. The reference was inspected
on October 23, 2026. The stylesheet implements that appearance for the
ObjectFramework content and navigation.

## Visual treatment

Use a white page, a white header, red `#c81418` headings and links, near-black
`#222222` body text, warm gray `#faf9f8` secondary surfaces, and fine gray
`#a9a9a8` rules between guide descriptions. The desktop reading column starts
near the left margin, while chapter navigation occupies the right margin.
The header contains a circular project symbol, the guide title and version,
a Guides Index disclosure, source, and contribution links.

Body text uses Inter at 16 pixels with a 1.4 line height. Headings are bold
sans serif, with red page titles and article chapter titles. Rails uses
Calibre for headings; this site uses locally installed Calibre when present
and the bundled open-font Inter otherwise. Code uses the same IBM Plex Mono
family as the reference, on dark warm-gray blocks with pale syntax colors.
Inter and IBM Plex Mono are self-hosted with their SIL Open Font Licenses;
no third-party font request is required.

The index uses section headings and ruled definition lists. Cyan and pale
yellow notes explain the reading path and executable examples in the right
margin. Article pages use a numbered chapter index there instead.

```text
Project symbol / Guides / Version          Guides Index / Contribute

Guide title and introduction               Chapters
                                            1. First concept
1. First concept                            2. Next concept
Working example and explanation
```

Below 1025 pixels, the header stacks, the article uses the available width,
and a native disclosure places chapter navigation before the article. The
Guides Index remains keyboard accessible at every width. A dark color scheme
follows the reference's dark surfaces and softer red links. Print styles
remove navigation while preserving the article.

ObjectFramework retains its own name, symbol, original explanations, and
executable examples. The stylesheet is maintained with the repository rather
than loading the Rails site's stylesheet at runtime. Validate generated links,
review desktop and mobile screenshots, exercise the disclosure and search with
a keyboard, and audit the rendered guide after visual changes.
