import 'package:flutter/material.dart';

enum ReaderSourceType { jhentai, komga, pdf }

extension ReaderSourceTypeExtension on ReaderSourceType {
  String get labelKey {
    switch (this) {
      case ReaderSourceType.jhentai:
        return 'readerSourceJHenTai';
      case ReaderSourceType.komga:
        return 'readerSourceKomga';
      case ReaderSourceType.pdf:
        return 'readerSourcePdf';
    }
  }

  IconData get icon {
    switch (this) {
      case ReaderSourceType.jhentai:
        return Icons.public;
      case ReaderSourceType.komga:
        return Icons.dns_outlined;
      case ReaderSourceType.pdf:
        return Icons.picture_as_pdf_outlined;
    }
  }
}
