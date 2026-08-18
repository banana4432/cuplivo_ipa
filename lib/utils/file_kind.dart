import 'package:path/path.dart' as p;

/// File-kind classification shared by the workspace file browser and the
/// storage space file list, so every surface routes the same file type to
/// the same in-app preview instead of the unreliable system-open fallback
/// (iOS Quick Look has no html support; Android throws
/// `ActivityNotFoundException` when no app handles the MIME).
abstract final class FileKind {
  FileKind._();

  static const Set<String> htmlExtensions = {'.html', '.htm'};

  /// Rendered by the built-in image codec (`FilePreviewPage` /
  /// `ImageViewerPage`). Kept in sync with the image set used there.
  static const Set<String> imageExtensions = {
    '.png',
    '.jpg',
    '.jpeg',
    '.gif',
    '.webp',
    '.svg',
  };

  /// Known binary formats that cannot be rendered or read as text in-app;
  /// these fall back to the system open. Unknown extensions intentionally
  /// return false so they route to the text preview, which binary-probes the
  /// content and shows a clear error for actual binaries.
  static const Set<String> binaryExtensions = {
    // Documents
    '.pdf',
    '.doc',
    '.docx',
    '.xls',
    '.xlsx',
    '.ppt',
    '.pptx',
    '.rtf',
    // Archives
    '.zip',
    '.rar',
    '.7z',
    '.tar',
    '.gz',
    '.bz2',
    '.xz',
    '.zst',
    // Executables & containers
    '.exe',
    '.dll',
    '.so',
    '.dylib',
    '.dmg',
    '.iso',
    '.msi',
    '.apk',
    '.aab',
    '.ipa',
    '.deb',
    '.rpm',
    '.bin',
    '.class',
    '.jar',
    // Audio
    '.mp3',
    '.m4a',
    '.aac',
    '.wav',
    '.flac',
    '.ogg',
    '.opus',
    '.wma',
    // Video
    '.mp4',
    '.m4v',
    '.mov',
    '.avi',
    '.mkv',
    '.wmv',
    '.webm',
    '.flv',
    // Images the built-in codec does not render
    '.bmp',
    '.tif',
    '.tiff',
    '.heic',
    '.heif',
    '.ico',
    // Fonts / vector / other
    '.ttf',
    '.otf',
    '.woff',
    '.woff2',
    '.eot',
    '.psd',
    '.ai',
    '.eps',
  };

  static bool isHtmlFile(String path) =>
      htmlExtensions.contains(p.extension(path).toLowerCase());

  static bool isImageFile(String path) =>
      imageExtensions.contains(p.extension(path).toLowerCase());

  static bool isSvgFile(String path) =>
      p.extension(path).toLowerCase() == '.svg';

  static bool isLikelyBinary(String path) =>
      binaryExtensions.contains(p.extension(path).toLowerCase());
}
