Design a custom avatar for my HeyDot menu bar app as one SVG file.

HeyDot draws the avatar in the macOS menu bar at 16 to 18 px, in its popover at 52 px and in Settings. It
must match the flat vector art style HeyDot's own dots use. Ask me what character I want if I haven't said.

## Style rules

1. Grid: a square `viewBox="0 0 96 96"`. Keep everything inside 3 to 93 (a 3-unit margin). Transparent
   background: no rectangle behind the character.
2. Body: one bold, flat silhouette in ink `#0A0A0B`, roughly 60 to 70 units wide. No outlines, gradients,
   shadows, textures or text.
3. Eyes: two pill (stadium) eyes, about 10.5 units wide and 18 tall, centres about 16 apart, a little below
   the middle (y about 56 to 60). Cut the eye holes out of the body (a compound path with
   `fill-rule="evenodd"`, or a body path that already has the holes), then put the eye shapes into those
   holes inside `<g id="eyes">...</g>`. HeyDot drops that group for the monochrome menu bar icon, so the
   eyes read as holes there.
4. Accent colour: exactly one, used for the eyes. Pick one of HeyDot's: pink `#FF5FA2`, orchid `#D65CF0`,
   violet `#7B61FF`, blue `#2F6BFF`, cyan `#1FC6F0`, teal `#12BFA0`, lime `#C6E82B`, yellow `#FFD21E`,
   coral `#FF7A1A`. (Or colour the whole body with the accent and make the eyes ink.)
5. Accessories (optional, one or two at most): flat shapes in the accent, ink, charcoal `#1F1F23` or brown
   `#8C5A3C`. Separate each one from the body with a gutter: cut a 3-unit gap out of the body around it
   instead of drawing an outline. Ears, hats, glasses or headphones never cover the eyes, and headphones
   pass behind ears rather than over them.
6. Menu bar legibility: at 18 px one unit is about a fifth of a pixel. No part thinner than 5 units, no gap
   narrower than 3 units, no detail smaller than 8 units. Render it at 16 and 18 px and check that the
   silhouette alone still reads as the character.

## Output contract (HeyDot checks this on import and refuses anything else)

- One `.svg` file, under 200 KB, UTF-8, root `<svg xmlns="http://www.w3.org/2000/svg" viewBox="0 0 96 96">`.
- Only these elements: `svg`, `g`, `path`, `circle`, `ellipse`, `rect`, `polygon`, `polyline`, `line`,
  `title`, `desc`. No `script`, `style`, `image`, `use`, `text`, `foreignObject`, filters, masks,
  gradients, DOCTYPE or entities.
- No links of any kind: no `href`, `xlink:href`, `url(...)`, `data:` or event attributes such as `onload`.
- Flat colours as `fill="#RRGGBB"` attributes.
- Exactly one `<g id="eyes">` holding the eye shapes, with no groups nested inside it.

When it's done, tell me the file's path. I'll import it in HeyDot: Design your dot > Custom avatar >
Import SVG or PNG. If you can render PNG previews at 16, 18 and 128 px, show me those too.
