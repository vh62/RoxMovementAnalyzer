platform :ios, '18.5'

target 'RoxMovementAnalyzer' do
  use_frameworks!

  pod 'MediaPipeTasksVision'

  target 'RoxMovementAnalyzerTests' do
    inherit! :search_paths
  end

  target 'RoxMovementAnalyzerUITests' do
    inherit! :search_paths
  end
end

# CocoaPods hands every `inherit! :search_paths` target the MediaPipe calculator graph's
# `-force_load`, which statically links every calculator into the test bundle as well as into the
# app. The bundle is then injected into a host app that has already registered them all, and
# MediaPipe's registry aborts the process from a static initialiser, before main:
#
#   F0000 registration.h:195] Function with name FlowLimiterCalculator already registered.
#
# It surfaces as "the test runner crashed before establishing connection", which looks like a broken
# test rather than a link-time problem. The test targets need MediaPipe's headers, not its symbols —
# the host app supplies those via BUNDLE_LOADER — so strip the flag from their generated configs.
post_install do |installer|
  support_files = Pathname.new(__dir__) + 'Pods' + 'Target Support Files'

  %w[Pods-RoxMovementAnalyzerTests Pods-RoxMovementAnalyzerUITests].each do |target|
    Dir.glob(support_files + target + '*.xcconfig').each do |path|
      contents = File.read(path)
      stripped = contents.gsub(/^OTHER_LDFLAGS\[sdk=iphone(?:os|simulator)\*\].*\n/, '')
      next if stripped == contents

      File.write(path, stripped)
      Pod::UI.puts "Removed the MediaPipe -force_load from #{File.basename(path)}"
    end
  end
end