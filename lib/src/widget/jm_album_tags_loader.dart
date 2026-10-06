import 'dart:async';

import 'package:flutter/widgets.dart';
import 'package:jhentai/src/model/gallery.dart';
import 'package:jhentai/src/service/jm_album_tag_service.dart';

/// Builds the card of the JM album [gallery], again when its tags become
/// known.
///
/// A JM list names an album's author only. While the card is on screen the
/// album's tags are asked from [jmAlbumTagService], and set on [gallery]
/// when they arrive, so that the list keeps them.
class JmAlbumTagsLoader extends StatefulWidget {
  const JmAlbumTagsLoader({super.key, required this.gallery, required this.builder});

  final Gallery gallery;
  final WidgetBuilder builder;

  @override
  State<JmAlbumTagsLoader> createState() => _JmAlbumTagsLoaderState();
}

class _JmAlbumTagsLoaderState extends State<JmAlbumTagsLoader> {
  StreamSubscription<({int albumId, JmAlbumTags tags})>? _loaded;
  int _albumId = 0;
  Object? _wanted;

  @override
  void initState() {
    super.initState();
    _attach();
  }

  @override
  void didUpdateWidget(JmAlbumTagsLoader oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (!identical(oldWidget.gallery, widget.gallery)) {
      _detach();
      _attach();
    }
  }

  @override
  void dispose() {
    _detach();
    super.dispose();
  }

  void _attach() {
    _albumId = widget.gallery.galleryUrl.jmChapterId;
    _loaded = jmAlbumTagService.loaded.listen((({int albumId, JmAlbumTags tags}) loaded) {
      if (loaded.albumId == _albumId) {
        setState(() => JmAlbumTagService.apply(widget.gallery, loaded.tags));
      }
    });
    if (JmAlbumTagService.lacksTags(widget.gallery)) {
      _wanted = jmAlbumTagService.want(_albumId);
    }
  }

  void _detach() {
    _loaded?.cancel();
    _loaded = null;
    if (_wanted != null) {
      jmAlbumTagService.unwant(_albumId, _wanted!);
      _wanted = null;
    }
  }

  @override
  Widget build(BuildContext context) => widget.builder(context);
}
