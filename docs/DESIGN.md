# Guides design and editorial brief

Readers are Ruby developers building applications from collaborating objects.
The site should work as a course and as a reference book. Each guide connects
a runnable example to the responsibility, invariant, and tradeoff behind it.

The palette uses paper white `#ffffff`, navy `#17334a`, body ink `#243746`,
Ruby red `#a5213c`, pale blue `#edf3f7`, and a quiet rule `#cbd7df`. Georgia is
the reading face; Trebuchet MS and system sans-serif provide navigation and
headings. Code uses the platform monospace stack. No external font request is
required. Body text stays near 70 characters per line.

The desktop layout places the ordered learning path beside a readable article,
with an in-page contents list in the right margin. On small screens, native
disclosure controls collapse navigation and contents. Text stays left aligned.

```text
ObjectFramework                 Guides / Source
------------------------------------------------
Learning path | Guide title        | On this page
              | Goals / prerequisites
              | Working example
              | Explanation and decisions
              | Failure cases
              | Next step
```

The index groups guides by the learning task and describes what each makes
possible. It uses a list of chapters, not repeated promotional panels. The
strong visual choice is the combination of a book-like reading column and a
visible path through object responsibilities. Code, diagrams, and explanations
carry the page; ornamental motion and generic marketing sections are omitted.

This brief was checked against the user's clarification: Rails Guides is a
reference for progression, explicit examples, and depth of explanation. Its
branding, wording, and layout are not copied. The visual treatment serves that
editorial objective and must remain readable with JavaScript disabled.
