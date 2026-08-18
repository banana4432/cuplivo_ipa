import 'package:Cuplivo/utils/file_kind.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  group('FileKind.isHtmlFile', () {
    test('matches .html and .htm case-insensitively, anywhere in the path', () {
      expect(FileKind.isHtmlFile('page.html'), isTrue);
      expect(FileKind.isHtmlFile('dir/sub/page.htm'), isTrue);
      expect(FileKind.isHtmlFile('page.HTML'), isTrue);
      expect(FileKind.isHtmlFile('page.Htm'), isTrue);
    });

    test('rejects other names', () {
      expect(FileKind.isHtmlFile('page.txt'), isFalse);
      expect(FileKind.isHtmlFile('page.html.backup'), isFalse);
      expect(FileKind.isHtmlFile('html'), isFalse);
      expect(FileKind.isHtmlFile('page'), isFalse);
    });
  });

  group('FileKind.isImageFile', () {
    test('matches the shared image set case-insensitively', () {
      expect(FileKind.isImageFile('a.png'), isTrue);
      expect(FileKind.isImageFile('a.jpg'), isTrue);
      expect(FileKind.isImageFile('a.jpeg'), isTrue);
      expect(FileKind.isImageFile('a.gif'), isTrue);
      expect(FileKind.isImageFile('a.webp'), isTrue);
      expect(FileKind.isImageFile('a.svg'), isTrue);
      expect(FileKind.isImageFile('a.PNG'), isTrue);
    });

    test('rejects non-images', () {
      expect(FileKind.isImageFile('a.txt'), isFalse);
      expect(FileKind.isImageFile('a.html'), isFalse);
      expect(FileKind.isImageFile('a.bmp'), isFalse);
      expect(FileKind.isImageFile('a.tiff'), isFalse);
    });
  });

  group('FileKind.isSvgFile', () {
    test('matches .svg case-insensitively only', () {
      expect(FileKind.isSvgFile('a.svg'), isTrue);
      expect(FileKind.isSvgFile('dir/a.SVG'), isTrue);
      expect(FileKind.isSvgFile('a.png'), isFalse);
      expect(FileKind.isSvgFile('a.svgz'), isFalse);
    });

    test('svg is image-classified but must NOT route to the raster-only '
        'ImageViewerPage (it decodes via FileImage)', () {
      expect(FileKind.isImageFile('a.svg'), isTrue);
      expect(FileKind.isSvgFile('a.svg'), isTrue);
    });
  });

  group('FileKind.isLikelyBinary', () {
    test('flags known binary formats case-insensitively', () {
      for (final name in [
        'a.pdf',
        'a.docx',
        'a.xlsx',
        'a.pptx',
        'a.zip',
        'a.tar.gz',
        'a.7z',
        'a.exe',
        'a.dmg',
        'a.apk',
        'a.mp3',
        'a.mp4',
        'a.mov',
        'a.mkv',
        'a.ttf',
        'a.PDF',
        'a.ZIP',
      ]) {
        expect(FileKind.isLikelyBinary(name), isTrue, reason: name);
      }
    });

    test('leaves text-like and unknown extensions to the text preview', () {
      for (final name in [
        'a.txt',
        'a.md',
        'a.json',
        'a.yaml',
        'a.dart',
        'a.py',
        'a.csv',
        'a.unknown',
        'a',
        'a.log',
      ]) {
        expect(FileKind.isLikelyBinary(name), isFalse, reason: name);
      }
    });

    test('html is text-like for the storage router (handled before it)', () {
      expect(FileKind.isLikelyBinary('a.html'), isFalse);
    });
  });
}
