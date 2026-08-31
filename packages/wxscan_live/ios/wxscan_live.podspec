# wxscan (iOS): AVFoundation delivers frames straight into the Rust scanner
# through the C ABI, without passing through Dart. The preview hands the same
# CVPixelBuffer to a Flutter texture.
#
# Nothing native is built here. The scanner is a Dart code asset, produced by
# the wxscan package's build hook and bundled by Flutter; the Swift side
# resolves its entry points with dlsym (see WxScanNative.swift), so the two
# packages share one copy of the library and of TFLite.
Pod::Spec.new do |s|
  s.name             = 'wxscan_live'
  s.version          = '0.1.0'
  s.summary          = 'Live QR scanning: camera frames go straight into the scanner, preview through a Flutter texture.'
  s.description      = <<-DESC
Live QR scanning. Frames go from AVFoundation into the native scanner without
passing through Dart; the preview is a Flutter texture backed by the same buffer.
                       DESC
  s.homepage         = 'https://github.com/wilinz/wxscan'
  s.license          = { :type => 'Apache-2.0' }
  s.author           = { 'wilinz' => 'wilinzza@gmail.com' }
  s.source           = { :path => '.' }
  # The Swift Package Manager layout, which CocoaPods builds from as well so
  # that there is one copy of the sources. `Package.swift` beside them is the
  # other half; see it for why the C header is a target of its own there.
  s.source_files     = 'wxscan_live/Sources/wxscan_live/**/*.swift',
                       'wxscan_live/Sources/wxscan_c/**/*.{h,c}'
  s.public_header_files = 'wxscan_live/Sources/wxscan_c/include/**/*.h'
  s.dependency 'Flutter'
  s.platform         = :ios, '13.0'
  s.swift_version    = '5.0'

  s.pod_target_xcconfig = {
    'DEFINES_MODULE' => 'YES',
    # Flutter.framework has no i386 slice.
    'EXCLUDED_ARCHS[sdk=iphonesimulator*]' => 'i386',
  }
end
