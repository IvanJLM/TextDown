---
title: Sample
tags: [demo]
---

# TextDown sample

A paragraph with **bold**, *italic*, ***both***, `inline code`, ~~strikethrough~~ and a [link to Apple](https://www.apple.com). Autolinks work too: https://github.com and www.example.com.
This line is a soft break, and this one ends with a hard break  
so it continues on a new line.

## Lists

- First item
- Second item with a longer text that should wrap nicely under itself when the window is narrow enough to need it
  - Nested item
    - Deeper item
- Third item

1. One
2. Two
   1. Two point one
3. Three

- [ ] A task to do
- [x] A task done

## Quote and code

> A quote that spans
> two lines.
>
> > And a nested quote.

```swift
struct Hello {
    let name = "TextDown"
	func greet() { print("Hello, \(name)") }  // tab-indented
}
```

### A table

| Feature | Supported | Notes |
|:--------|:---------:|------:|
| Tables | Yes | aligned |
| Empty cells | | right |
| Code | `yes` | |

---

#### Heading four
##### Heading five
###### Heading six

<p align="center">
  <img src="Image.png" alt="Logo" width="120">
  <br>
  <b>Centered HTML</b>
</p>

![An image](Image.png)

![Remote image](https://example.com/image.png)

Jump back to the [top](#textdown-sample) or to [Lists](#lists).

- A list item with code:

  ```
  indented code block
  ```

  > and a quote inside the item
