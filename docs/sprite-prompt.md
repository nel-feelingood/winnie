# Промпт для агента-художника: спрайты Винни

Скопируй блок ниже целиком. Он на английском, потому что графические модели лучше слушаются английского.

---

You are drawing a sprite set for a personal macOS desktop pet. It will not be published or distributed.

## Character

Winnie-the-Pooh as he appears in the 1969–1972 Soviet animated films directed by Fyodor Khitruk (Soyuzmultfilm). NOT the Disney version: no red shirt, no yellow fur.

Key features to keep identical on every sprite:
- Compact, round, potato-shaped body; the head merges into the torso with almost no neck.
- Dark chocolate-brown fur; a lighter tan/beige muzzle area; noticeably darker, almost black paws and ears.
- Small round ears set wide apart; large black oval nose; small expressive eyes with thick lids; short stubby legs; arms that look slightly detached, like paper cut-outs.
- Flat 2D cut-out (perekladka) animation look: rough, slightly uneven hand-drawn dark outline, flat colour fills with a subtle gouache/pencil texture. No gradients, no 3D shading, no glossy highlights, no drop shadow.

## Technical requirements (strict)

- 7 separate PNG files, each exactly 1024×1024 px, one pose per file.
- Transparent background (real alpha channel). If you cannot output alpha, fill the background with flat pure magenta `#FF00FF` — no gradients, no shadows, no texture — so it can be keyed out.
- Full body visible, facing the viewer in a 3/4 front view, no cropping. Leave at least 60 px of empty margin on every side.
- Same character scale, same proportions, same colours, same line weight on every sprite. The feet stand on the same baseline — the bottom of the feet sits at y ≈ 940 px, and the body is centred horizontally — so the character does not jump when sprites are swapped.
- No ground, no shadow under the feet, no props unless listed below, no text, no frame, no watermark.
- The sprite is shown small on screen (about 120–160 pt tall), so the silhouette and the facial expression must read clearly at small size. Prefer bold poses over fine detail.

## Sprites

| File | State | Pose |
|---|---|---|
| `idle.png` | Default, resting | Standing calmly, arms down at the sides, neutral, slightly dreamy expression, looking at the viewer. |
| `hover.png` | The mouse pointer is over him | Noticed you: eyes wider, eyebrows up, head slightly tilted, one paw raised in a small greeting. |
| `thinking.png` | Waiting for the model's answer | Classic "thinking Pooh": one paw scratching the top of the head or tapping the temple, eyes looking up and to the side, mouth pressed shut. |
| `talking.png` | The answer is arriving | Mouth open mid-sentence, one paw raised with an explaining / lecturing gesture, lively eyes looking at the viewer. |
| `drag.png` | Being dragged across the screen with the mouse | Lifted by the scruff: body hanging, arms and legs dangling loosely downward, surprised round eyes, mouth a small "o". Still centred in the canvas; the feet may be above the baseline here. |
| `error.png` | Something went wrong (no network, API error) | Puzzled and a bit upset: shoulders dropped, both paws spread in a "I don't know" shrug, eyebrows tilted, mouth turned down. |
| `sleep.png` | Idle for a long time | Sitting on the ground, legs stretched forward, head dropped to the chest, eyes closed, paws resting on the belly. The seat is on the baseline. |

## Process

1. First draw `idle.png` alone and treat it as the character sheet. Show it for approval before drawing the others.
2. Draw the remaining six sprites using `idle.png` as the strict reference for proportions, palette and line.
3. Deliver a single ZIP archive named `winnie-sprites.zip` containing exactly the seven files, named exactly as in the table, lowercase.
