# memefolder

![meme folder logo](Assets/Images/CroppedLogo.png)

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

### score filter (post-filters semantic results)
`@score>50` `@score<50` `@score=50` `@score>=50` `@score<=50`

filters by similarity score (0-100). only works when semantic search text is present

### boolean operators
`&` = AND, `|` = OR, `!` = NOT, `(` `)` = grouping

(more in [wiki](https://github.com/dsinkerii/memefolder/wiki/tags))

### example
```
program fl studio @image @score>50
``` 

semantic search for "program fl studio", filter images only, min score 50.

# TROUBLESHOOTING

### - the app uses CPU only!

memefolder uses [onnxruntime_v2](https://pub.dev/packages/onnxruntime_v2) as it's backend for models, refer to the troubleshooting from there:

Windows (NVIDIA):

- Install [CUDA Toolkit](https://developer.nvidia.com/cuda-downloads)
- Optional: [TensorRT](https://developer.nvidia.com/tensorrt) for extra speed

Windows (Any GPU):

 - DirectML works out-of-the-box on Windows 10+

Linux (NVIDIA):

- Install CUDA runtime: `apt install nvidia-cuda-toolkit`
- Optional: TensorRT

Linux (AMD):

 - Install [ROCm](https://www.amd.com/en/products/software/rocm.html)

hint: easiest win is to install TensorRT on any platform, as CUDA is a pain in the ahh during troubleshooting

# PERSONAL BENCHMARK

indexing (w/ Samsung 990 Pro 2tb):
- memes folder contains 2939 files, 23.8 Gb total, 2261 of which are videos&gifs (rest are images)
- 2939 files indexed in 5 minutes

running this on an Intel Core i5-9600KF (no acceleration):
- 40 files embedded in 20 minutes (so full would take >12 hours)

running this on an RTX 3060 (CUDA runtime)
- 192 files in ~15 minutes (so full embedding would take ~4 hours)