# frozen_string_literal: true

require_relative 'xcframework_converter/version'

require 'cocoapods'
require 'cocoapods/xcode/xcframework'
require 'fileutils'
require 'xcodeproj'

# rubocop:disable Metrics/AbcSize, Metrics/CyclomaticComplexity, Metrics/ModuleLength, Metrics/PerceivedComplexity

# Converts a framework (static or dynamic) to XCFrameworks, adding an arm64 simulator patch.
# For more info:
# static libs: https://bogo.wtf/arm64-to-sim.html
# dylibs: https://bogo.wtf/arm64-to-sim-dylibs.html
module XCFrameworkConverter
  class << self
    def convert_frameworks_to_xcframeworks!(installer)
      installer.analysis_result.specifications.each do |spec|
        next if spec.source && spec.local?

        frameworks_to_convert = spec.available_platforms.map do |platform|
          consumer = Pod::Specification::Consumer.new(spec, platform)
          before_rename = consumer.vendored_frameworks.select { |f| File.extname(f) == '.framework' }
          next [] if before_rename.empty?

          after_rename = before_rename.map { |f| Pathname.new(f).sub_ext('.xcframework').to_s }
          proxy = Pod::Specification::DSL::PlatformProxy.new(spec, platform.symbolic_name)
          proxy.vendored_frameworks = consumer.vendored_frameworks - before_rename + after_rename
          before_rename
        end.flatten.uniq

        next if frameworks_to_convert.empty?

        pod_path = installer.sandbox.pod_dir(Pod::Specification.root_name(spec.name))
        convert_xcframeworks_if_present(frameworks_to_convert.map { |f| pod_path.join(f) })

        # some pods put these as a way to NOT support arm64 sim
        # may stop working if a pod decides to put these in a platform proxy
        spec.attributes_hash['pod_target_xcconfig']&.delete('EXCLUDED_ARCHS[sdk=iphonesimulator*]')
        spec.attributes_hash['user_target_xcconfig']&.delete('EXCLUDED_ARCHS[sdk=iphonesimulator*]')
      end
    end

    def convert_xcframeworks_if_present(frameworks_to_convert)
      frameworks_to_convert.each do |path|
        convert_framework_to_xcframework(path) if Dir.exist?(path)
      end
    end

    def plist_template_path
      Pathname.new(__FILE__).dirname.join('xcframework_template.plist')
    end

    def convert_framework_to_xcframework(path)
      plist = Xcodeproj::Plist.read_from_path(plist_template_path)
      xcframework_path = Pathname.new(path).sub_ext('.xcframework')
      xcframework_path.mkdir
      plist['AvailableLibraries'].each do |slice|
        slice_path = xcframework_path.join(slice['LibraryIdentifier'])
        slice_path.mkdir
        slice['LibraryPath'] = File.basename(path)
        FileUtils.cp_r(path, slice_path)
      end
      Xcodeproj::Plist.write_to_path(plist, xcframework_path.join('Info.plist'))
      FileUtils.rm_rf(path)
      final_framework = open_xcframework(xcframework_path)
      final_framework.slices.each do |slice|
        patch_arm_binary(slice) if slice.platform == :ios && slice.platform_variant == :simulator
        cleanup_unused_archs(slice)
      end
    end

    def open_xcframework(xcframework_path)
      if Pod::Xcode::XCFramework.instance_method(:initialize).arity == 2
        Pod::Xcode::XCFramework.new(File.basename(xcframework_path), xcframework_path.realpath)
      else
        Pod::Xcode::XCFramework.new(xcframework_path.realpath)
      end
    end

    def patch_arm_binary(slice)
      require 'macho'

      case slice.build_type.linkage
      when :dynamic
        patch_arm_binary_dynamic(slice)
      when :static
        patch_arm_binary_static(slice)
      end

      slice.path.glob('**/arm64*.swiftinterface').each do |interface_file|
        `sed -i '' -E 's/target arm64-apple-ios([0-9.]+) /target arm64-apple-ios\\1-simulator /g' "#{interface_file}"`
      end
    end

    def patch_arm_binary_dynamic(slice)
      extracted_path = slice.path.join('arm64.dylib')
      `xcrun lipo \"#{slice.binary_path}\" -thin arm64 -output \"#{extracted_path}\"`

      file = MachO::MachOFile.new(extracted_path)
      sdk_version = file[:LC_VERSION_MIN_IPHONEOS].first.version_string
      `xcrun vtool -arch arm64 -set-build-version 7 #{sdk_version} #{sdk_version} -replace -output \"#{extracted_path}\" \"#{extracted_path}\"`
      `xcrun lipo \"#{slice.binary_path}\" -replace arm64 \"#{extracted_path}\" -output \"#{slice.binary_path}\"`
      extracted_path.rmtree
    end

    def arm2sim_path
      Pathname.new(__FILE__).dirname.join('arm2sim.swift')
    end

    def patch_arm_binary_static(slice)
      extracted_path = slice.path.join('arm64.a')
      `xcrun lipo \"#{slice.binary_path}\" -thin arm64 -output \"#{extracted_path}\"`
      extracted_path_dir = slice.path.join('arm64-objects')
      extracted_path_dir.mkdir
      `cd \"#{extracted_path_dir}\" ; ar x \"#{extracted_path}\"`
      Dir[extracted_path_dir.join('*.o')].each do |object_file|
        file = MachO::MachOFile.new(object_file)
        sdk_version = file[:LC_VERSION_MIN_IPHONEOS].first.version_string.to_i
        `xcrun swift \"#{arm2sim_path}\" \"#{object_file}\" \"#{sdk_version}\" \"#{sdk_version}\"`
      end
      `cd \"#{extracted_path_dir}\" ; ar crv \"#{extracted_path}\" *.o`

      `xcrun lipo \"#{slice.binary_path}\" -replace arm64 \"#{extracted_path}\" -output \"#{slice.binary_path}\"`
      extracted_path_dir.rmtree
      extracted_path.rmtree
    end

    def cleanup_unused_archs(slice)
      supported_archs = slice.supported_archs
      unsupported_archs = `xcrun lipo \"#{slice.binary_path}\" -archs`.split - supported_archs
      unsupported_archs.each do |arch|
        `xcrun lipo \"#{slice.binary_path}\" -remove \"#{arch}\" -output \"#{slice.binary_path}\"`
      end
    end
  end
end
