# memefolder

![meme folder logo](Assets/Images/FullLogo.png)

lets you find that *one* specific meme by the context/tags of it.

# HOW 2 INSTALL
- goto [latest release here](https://github.com/dsinkerii/memefolder/releases/latest)
- install
- finish the tutorial
- you're done!

# WHAT DOES IT HAVE? WHAT IS IT?
ever found yourself in that one position of not knowing where your meme is, somewhere nested deeeeep inside your memes folder? **memefolder** is here to help! using the awesome technology of semantic search, you can search for your memes using context, as well as narrow down the search using cool tags!

![screenshot1](screenshot1.png)

# WHAT TAGS ARE AVAILABLE:

### file type filters
| tag | filters |
|-----|---------|
| `@image` / `@picture` / `@photo` | media_type = image |
| `@video` | media_type = video |
| `@audio` / `@sound` | media_type = audio |
| `@text` | media_type = text |
| `@gif` | ext = gif |

### file extension filters
`@.mp4` `@.jpg` `@.jpeg` `@.png` `@.gif` `@.webm` `@.webp` `@.svg` `@.mp3` `@.wav` `@.ogg` `@.flac` `@.mkv` `@.avi` `@.mov`

any 2-4 letter extension works

### folder filter
`@folder:path/to/subfolder` - limits to files under that relative path.

### semantic content mode
| Tag | Effect |
|-----|--------|
| `@imagecontent` | force CLIP (image+video) embedding search |
| `@audiocontent` | force CLAP (audio+video) embedding search |

default: CLIP if neither specified.

### score filter (post-filters semantic results)
`@score>50` `@score<50` `@score=50` `@score>=50` `@score<=50`

filters by similarity score (0-100). only works when semantic search text is present

### boolean operators
`&` = AND, `|` = OR, `!` = NOT, `(` `)` = grouping

### reserved (highlighting only, no filtering yet)
`@date>YYYY` `@size>10mb` `@length>5s` `@duration>5s` `@width>1920` `@height>1080` `@fps>30`
`@has:audio` `@has:speech` `@has:text`

### example
```
program fl studio @image @score>50
``` 

semantic search for "program fl studio", filter images only, min score 50.
