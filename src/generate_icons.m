#import <Cocoa/Cocoa.h>

// Vector icon definitions from Phosphor Icons (MIT License - https://phosphoricons.com)
// Copyright (c) 2023 Phosphor Icons

static NSString * const kPathPlay = @"M240,128a15.74,15.74,0,0,1-7.6,13.51L88.32,229.65a16,16,0,0,1-16.2.3A15.86,15.86,0,0,1,64,216.13V39.87a15.86,15.86,0,0,1,8.12-13.82,16,16,0,0,1,16.2.3L232.4,114.49A15.74,15.74,0,0,1,240,128Z";

static NSString * const kPathPause = @"M216,48V208a16,16,0,0,1-16,16H160a16,16,0,0,1-16-16V48a16,16,0,0,1,16-16h40A16,16,0,0,1,216,48ZM96,32H56A16,16,0,0,0,40,48V208a16,16,0,0,0,16,16H96a16,16,0,0,0,16-16V48A16,16,0,0,0,96,32Z";

static NSString * const kPathPlayPause = @"M184,64V192a8,8,0,0,1-16,0V64a8,8,0,0,1,16,0Zm40-8a8,8,0,0,0-8,8V192a8,8,0,0,0,16,0V64A8,8,0,0,0,224,56Zm-87.33,58.66L48.48,58.51A15.91,15.91,0,0,0,24,71.85v112.3A15.83,15.83,0,0,0,32.23,198a15.95,15.95,0,0,0,16.25-.53l88.19-56.15a15.8,15.8,0,0,0,0-26.68Z";

static NSString * const kPathNext = @"M208,40V216a8,8,0,0,1-16,0V146.77L72.43,221.55A15.95,15.95,0,0,1,48,208.12V47.88A15.95,15.95,0,0,1,72.43,34.45L192,109.23V40a8,8,0,0,1,16,0Z";

static NSString * const kPathPrevious = @"M208,47.88V208.12a16,16,0,0,1-14.43,13.43L64,146.77V216a8,8,0,0,1-16,0V40a8,8,0,0,1,16,0v69.23L183.57,34.45A15.95,15.95,0,0,1,208,47.88Z";

static NSString * const kPathMusicNote = @"M212.92,17.71a7.89,7.89,0,0,0-6.86-1.46l-128,32A8,8,0,0,0,72,56V166.1A36,36,0,1,0,88,196V102.25l112-28V134.1A36,36,0,1,0,216,164V24A8,8,0,0,0,212.92,17.71Z";

static NSString * const kPathMic = @"M80,128V64a48,48,0,0,1,96,0v64a48,48,0,0,1-96,0Zm128,0a8,8,0,0,0-16,0,64,64,0,0,1-128,0,8,8,0,0,0-16,0,80.11,80.11,0,0,0,72,79.6V240a8,8,0,0,0,16,0V207.6A80.11,80.11,0,0,0,208,128Z";

static NSString * const kPathMicSlash = @"M213.38,229.92a8,8,0,0,1-11.3-.54l-30.92-34A78.83,78.83,0,0,1,136,207.59V240a8,8,0,0,1-16,0V207.6A80.11,80.11,0,0,1,48,128a8,8,0,0,1,16,0,64.07,64.07,0,0,0,64,64,63.41,63.41,0,0,0,32.21-8.68l-11.1-12.2A48,48,0,0,1,80,128V95.09L42.08,53.38A8,8,0,0,1,53.92,42.62l160,176A8,8,0,0,1,213.38,229.92Zm-24.19-63.13a7.88,7.88,0,0,0,3.51.82,8,8,0,0,0,7.19-4.49A79.16,79.16,0,0,0,208,128a8,8,0,0,0-16,0,63.32,63.32,0,0,1-6.48,28.09A8,8,0,0,0,189.19,166.79Zm-27.33-29.22A8,8,0,0,0,175.74,133a49.49,49.49,0,0,0,.26-5V64A48,48,0,0,0,84,44.87a8,8,0,0,0,1.41,8.57Z";

static void renderExactPNG(NSImage *img, int pixels, NSString *destPath) {
    NSBitmapImageRep *rep = [[NSBitmapImageRep alloc] initWithBitmapDataPlanes:NULL
                                                                    pixelsWide:pixels
                                                                    pixelsHigh:pixels
                                                                 bitsPerSample:8
                                                               samplesPerPixel:4
                                                                      hasAlpha:YES
                                                                      isPlanar:NO
                                                                colorSpaceName:NSCalibratedRGBColorSpace
                                                                  bytesPerRow:0
                                                                 bitsPerPixel:0];
    [NSGraphicsContext saveGraphicsState];
    [NSGraphicsContext setCurrentContext:[NSGraphicsContext graphicsContextWithBitmapImageRep:rep]];
    [img drawInRect:NSMakeRect(0, 0, pixels, pixels) fromRect:NSZeroRect operation:NSCompositingOperationCopy fraction:1.0];
    [NSGraphicsContext restoreGraphicsState];

    NSData *pngData = [rep representationUsingType:NSBitmapImageFileTypePNG properties:@{}];
    [pngData writeToFile:destPath atomically:YES];
}

static void createIcon(NSString *outputDir, NSString *name, NSString *pathData, BOOL isGradient) {
    NSString *svgContent;
    if (isGradient) {
        // Gradient badge for plugin icon
        svgContent = [NSString stringWithFormat:
            @"<svg xmlns=\"http://www.w3.org/2000/svg\" viewBox=\"0 0 256 256\">\n"
            @"  <defs>\n"
            @"    <linearGradient id=\"g\" x1=\"0%%\" y1=\"0%%\" x2=\"100%%\" y2=\"100%%\">\n"
            @"      <stop offset=\"0%%\" stop-color=\"#8B5CF6\"/>\n"
            @"      <stop offset=\"100%%\" stop-color=\"#4F46E5\"/>\n"
            @"    </linearGradient>\n"
            @"  </defs>\n"
            @"  <rect width=\"256\" height=\"256\" rx=\"52\" fill=\"url(#g)\"/>\n"
            @"  <g transform=\"translate(38.4, 38.4) scale(0.70)\">\n"
            @"    <path d=\"%@\" fill=\"#FFFFFF\"/>\n"
            @"  </g>\n"
            @"</svg>\n", pathData];
    } else {
        // High-contrast dark tile badge for action keys
        svgContent = [NSString stringWithFormat:
            @"<svg xmlns=\"http://www.w3.org/2000/svg\" viewBox=\"0 0 256 256\">\n"
            @"  <rect width=\"256\" height=\"256\" rx=\"48\" fill=\"#22222A\"/>\n"
            @"  <rect width=\"256\" height=\"256\" rx=\"48\" fill=\"none\" stroke=\"#383846\" stroke-width=\"4\"/>\n"
            @"  <g transform=\"translate(38.4, 38.4) scale(0.70)\">\n"
            @"    <path d=\"%@\" fill=\"#FFFFFF\"/>\n"
            @"  </g>\n"
            @"</svg>\n", pathData];
    }

    // 1. Save .svg file
    NSString *svgPath = [NSString stringWithFormat:@"%@/%@.svg", outputDir, name];
    [svgContent writeToFile:svgPath atomically:YES encoding:NSUTF8StringEncoding error:nil];

    // Load SVG into NSImage
    NSImage *svgImage = [[NSImage alloc] initWithContentsOfFile:svgPath];
    if (!svgImage) {
        NSLog(@"[Error] Failed to load generated SVG: %@", svgPath);
        return;
    }

    // 2. Render 72x72 PNG (standard Stream Deck)
    NSString *png72 = [NSString stringWithFormat:@"%@/%@.png", outputDir, name];
    renderExactPNG(svgImage, 72, png72);

    // 3. Render 144x144 PNG (Retina Stream Deck @2x)
    NSString *png144 = [NSString stringWithFormat:@"%@/%@@2x.png", outputDir, name];
    renderExactPNG(svgImage, 144, png144);

    // 4. Render 128x128 PNG (OpenDeck starterpack size)
    NSString *png128 = [NSString stringWithFormat:@"%@/%@_128.png", outputDir, name];
    renderExactPNG(svgImage, 128, png128);
}

static void createMicIcon(NSString *outputDir, NSString *name, BOOL isLive) {
    NSString *svgContent;
    if (isLive) {
        svgContent = [NSString stringWithFormat:
            @"<svg xmlns=\"http://www.w3.org/2000/svg\" viewBox=\"0 0 256 256\">\n"
            @"  <rect width=\"256\" height=\"256\" rx=\"48\" fill=\"#1A2421\"/>\n"
            @"  <rect width=\"256\" height=\"256\" rx=\"48\" fill=\"none\" stroke=\"#10B981\" stroke-width=\"6\"/>\n"
            @"  <rect x=\"136\" y=\"18\" width=\"98\" height=\"38\" rx=\"10\" fill=\"#10B981\"/>\n"
            @"  <text x=\"185\" y=\"45\" font-family=\"-apple-system, system-ui, sans-serif\" font-weight=\"bold\" font-size=\"22\" fill=\"#FFFFFF\" text-anchor=\"middle\">100%%</text>\n"
            @"  <g transform=\"translate(51.2, 51.2) scale(0.60)\">\n"
            @"    <path d=\"%@\" fill=\"#10B981\"/>\n"
            @"  </g>\n"
            @"</svg>\n", kPathMic];
    } else {
        svgContent = [NSString stringWithFormat:
            @"<svg xmlns=\"http://www.w3.org/2000/svg\" viewBox=\"0 0 256 256\">\n"
            @"  <rect width=\"256\" height=\"256\" rx=\"48\" fill=\"#2A1D1F\"/>\n"
            @"  <rect width=\"256\" height=\"256\" rx=\"48\" fill=\"none\" stroke=\"#EF4444\" stroke-width=\"6\"/>\n"
            @"  <rect x=\"158\" y=\"18\" width=\"76\" height=\"38\" rx=\"10\" fill=\"#EF4444\"/>\n"
            @"  <text x=\"196\" y=\"45\" font-family=\"-apple-system, system-ui, sans-serif\" font-weight=\"bold\" font-size=\"22\" fill=\"#FFFFFF\" text-anchor=\"middle\">0%%</text>\n"
            @"  <g transform=\"translate(51.2, 51.2) scale(0.60)\">\n"
            @"    <path d=\"%@\" fill=\"#EF4444\"/>\n"
            @"  </g>\n"
            @"</svg>\n", kPathMicSlash];
    }

    NSString *svgPath = [NSString stringWithFormat:@"%@/%@.svg", outputDir, name];
    [svgContent writeToFile:svgPath atomically:YES encoding:NSUTF8StringEncoding error:nil];

    NSImage *svgImage = [[NSImage alloc] initWithContentsOfFile:svgPath];
    if (!svgImage) {
        NSLog(@"[Error] Failed to load generated SVG: %@", svgPath);
        return;
    }

    NSString *png72 = [NSString stringWithFormat:@"%@/%@.png", outputDir, name];
    renderExactPNG(svgImage, 72, png72);

    NSString *png144 = [NSString stringWithFormat:@"%@/%@@2x.png", outputDir, name];
    renderExactPNG(svgImage, 144, png144);

    NSString *png128 = [NSString stringWithFormat:@"%@/%@_128.png", outputDir, name];
    renderExactPNG(svgImage, 128, png128);
}

int main(int argc, const char * argv[]) {
    @autoreleasepool {
        NSString *dir = @"icons";
        if (argc > 1) {
            dir = [NSString stringWithUTF8String:argv[1]];
        }

        [[NSFileManager defaultManager] createDirectoryAtPath:dir withIntermediateDirectories:YES attributes:nil error:nil];

        NSLog(@"Generating icons using Phosphor Icons (MIT License)...");

        // Generate media playback icons
        createIcon(dir, @"plugin", kPathMusicNote, YES);
        createIcon(dir, @"playpause", kPathPlayPause, NO);
        createIcon(dir, @"play", kPathPlay, NO);
        createIcon(dir, @"pause", kPathPause, NO);
        createIcon(dir, @"next", kPathNext, NO);
        createIcon(dir, @"previous", kPathPrevious, NO);
        createIcon(dir, @"actionDefaultImage", kPathPlayPause, NO);

        // Generate microphone status icons
        createMicIcon(dir, @"mic_on", YES);
        createMicIcon(dir, @"mic_off", NO);
        createMicIcon(dir, @"mic", YES);

        // Copy Phosphor LICENSE into icons directory
        NSString *licenseText =
            @"MIT License\n\n"
            @"Copyright (c) 2023 Phosphor Icons\n\n"
            @"Permission is hereby granted, free of charge, to any person obtaining a copy\n"
            @"of this software and associated documentation files (the \"Software\"), to deal\n"
            @"in the Software without restriction, including without limitation the rights\n"
            @"to use, copy, modify, merge, publish, distribute, sublicense, and/or sell\n"
            @"copies of the Software, and to permit persons to whom the Software is\n"
            @"furnished to do so, subject to the following conditions:\n\n"
            @"The above copyright notice and this permission notice shall be included in all\n"
            @"copies or substantial portions of the Software.\n\n"
            @"THE SOFTWARE IS PROVIDED \"AS IS\", WITHOUT WARRANTY OF ANY KIND, EXPRESS OR\n"
            @"IMPLIED, INCLUDING BUT NOT LIMITED TO THE WARRANTIES OF MERCHANTABILITY,\n"
            @"FITNESS FOR A PARTICULAR PURPOSE AND NONINFRINGEMENT. IN NO EVENT SHALL THE\n"
            @"AUTHORS OR COPYRIGHT HOLDERS BE LIABLE FOR ANY CLAIM, DAMAGES OR OTHER\n"
            @"LIABILITY, WHETHER IN AN ACTION OF CONTRACT, TORT OR OTHERWISE, ARISING FROM,\n"
            @"OUT OF OR IN CONNECTION WITH THE SOFTWARE OR THE USE OR OTHER DEALINGS IN THE\n"
            @"SOFTWARE.\n";

        [licenseText writeToFile:[NSString stringWithFormat:@"%@/LICENSE", dir]
                      atomically:YES
                        encoding:NSUTF8StringEncoding
                           error:nil];

        NSLog(@"All Phosphor Icons successfully generated in %@", dir);
    }
    return 0;
}
