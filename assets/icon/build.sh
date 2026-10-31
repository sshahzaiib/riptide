#!/bin/sh
# Render every icon asset from the SVGs in this folder. macOS tools only.
# ponytail: qlmanage is the rasterizer (WebKit, so SVG masks/filters and SF Pro Rounded work).
set -e
cd "$(dirname "$0")"
render() { # render <svg> <width px> <out png> [height px]  (qlmanage pads to a square, so crop when given a height)
  t=$(mktemp -d); qlmanage -t -s "$2" -o "$t" "$1" >/dev/null 2>&1; mv "$t/$(basename "$1").png" "$3"; rmdir "$t"
  if [ -n "$4" ]; then sips -c "$4" "$2" "$3" >/dev/null; fi
}
STRIP=$(mktemp -d)/strip-alpha; swiftc -O strip-alpha.swift -o "$STRIP" 2>/dev/null
opaque() { "$STRIP" "$@"; } # re-encode PNGs without an alpha channel (tvOS back layer / top shelf must be opaque)

# --- macOS: Icon Composer package (Tahoe glass) + flat .icns fallback
mkdir -p Riptide.icon/Assets
render ribbon.svg 1024 Riptide.icon/Assets/ribbon.png
cat > Riptide.icon/icon.json <<'JSON'
{
  "fill-specializations" : [
    { "value" : { "solid" : "srgb:0.98039,0.98039,0.96863,1.00000" } },
    { "appearance" : "dark", "value" : { "solid" : "srgb:0.10196,0.10980,0.12157,1.00000" } }
  ],
  "groups" : [ {
    "layers" : [ { "name" : "ribbon", "image-name" : "ribbon.png", "glass" : true, "hidden" : false,
                   "position" : { "scale" : 1, "translation-in-points" : [ 0, 0 ] } } ],
    "lighting" : "individual",
    "shadow" : { "kind" : "neutral", "opacity" : 0.4 },
    "specular" : true,
    "translucency" : { "enabled" : false, "value" : 0 }
  } ],
  "supported-platforms" : { "squares" : "shared" }
}
JSON
rm -rf AppIcon.iconset && mkdir AppIcon.iconset
for s in 16 32 128 256 512; do
  render mac-light.svg $s "AppIcon.iconset/icon_${s}x${s}.png"
  render mac-light.svg $((s*2)) "AppIcon.iconset/icon_${s}x${s}@2x.png"
done
iconutil -c icns AppIcon.iconset -o ../AppIcon.icns && rm -rf AppIcon.iconset

# --- tvOS: layered app icon + top shelf into the asset catalog
B="../../RiptideTV/Assets.xcassets/App Icon & Top Shelf Image.brandassets"
rm -rf "$B"; mkdir -p "$B"
info='"info" : { "author" : "xcode", "version" : 1 }'
cat > "$B/Contents.json" <<JSON
{ "assets" : [
    { "filename" : "App Icon - App Store.imagestack", "idiom" : "tv", "role" : "primary-app-icon", "size" : "1280x768" },
    { "filename" : "App Icon.imagestack", "idiom" : "tv", "role" : "primary-app-icon", "size" : "400x240" },
    { "filename" : "Top Shelf Image Wide.imageset", "idiom" : "tv", "role" : "top-shelf-image-wide", "size" : "2320x720" },
    { "filename" : "Top Shelf Image.imageset", "idiom" : "tv", "role" : "top-shelf-image", "size" : "1920x720" } ],
  $info }
JSON
stack() { # stack <dir> <1x width> [2x width]
  mkdir -p "$1"
  echo "{ \"layers\" : [ { \"filename\" : \"Front.imagestacklayer\" }, { \"filename\" : \"Back.imagestacklayer\" } ], $info }" > "$1/Contents.json"
  for L in Front Back; do
    d="$1/$L.imagestacklayer"; mkdir -p "$d/Content.imageset"
    echo "{ $info }" > "$d/Contents.json"
    src=$(echo $L | tr A-Z a-z)
    render tv-$src.svg $2 "$d/Content.imageset/$src.png" $(($2*3/5))
    [ $L = Back ] && opaque "$d/Content.imageset/$src.png"
    if [ -n "$3" ]; then
      render tv-$src.svg $3 "$d/Content.imageset/$src@2x.png" $(($3*3/5))
      [ $L = Back ] && opaque "$d/Content.imageset/$src@2x.png"
      echo "{ \"images\" : [ { \"idiom\" : \"tv\", \"filename\" : \"$src.png\", \"scale\" : \"1x\" }, { \"idiom\" : \"tv\", \"filename\" : \"$src@2x.png\", \"scale\" : \"2x\" } ], $info }" > "$d/Content.imageset/Contents.json"
    else
      echo "{ \"images\" : [ { \"idiom\" : \"tv\", \"filename\" : \"$src.png\", \"scale\" : \"1x\" } ], $info }" > "$d/Content.imageset/Contents.json"
    fi
  done
}
stack "$B/App Icon.imagestack" 400 800
stack "$B/App Icon - App Store.imagestack" 1280
shelf() { # shelf <dir> <svg> <1x width>
  mkdir -p "$1"; render "$2" $3 "$1/shelf.png" 720; render "$2" $(($3*2)) "$1/shelf@2x.png" 1440
  opaque "$1/shelf.png"; opaque "$1/shelf@2x.png"
  echo "{ \"images\" : [ { \"idiom\" : \"tv\", \"filename\" : \"shelf.png\", \"scale\" : \"1x\" }, { \"idiom\" : \"tv\", \"filename\" : \"shelf@2x.png\", \"scale\" : \"2x\" } ], $info }" > "$1/Contents.json"
}
shelf "$B/Top Shelf Image.imageset" topshelf-1920.svg 1920
shelf "$B/Top Shelf Image Wide.imageset" topshelf-2320.svg 2320
echo "built: assets/AppIcon.icns, assets/icon/Riptide.icon, RiptideTV brandassets"
