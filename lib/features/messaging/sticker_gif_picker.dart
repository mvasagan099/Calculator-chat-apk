import 'package:flutter/material.dart';

class StickerItem {
  const StickerItem({
    required this.id,
    required this.emoji,
    required this.title,
    this.category = 'General',
  });
  final String id, emoji, title, category;
}

class GifItem {
  const GifItem({
    required this.id,
    required this.url,
    required this.title,
    this.category = 'Trending',
  });
  final String id, url, title, category;
}

class StickerGifPicker extends StatefulWidget {
  const StickerGifPicker({
    super.key,
    required this.onSelectSticker,
    required this.onSelectGif,
  });

  final void Function(Map<String, dynamic> stickerData) onSelectSticker;
  final void Function(Map<String, dynamic> gifData) onSelectGif;

  @override
  State<StickerGifPicker> createState() => _StickerGifPickerState();
}

class _StickerGifPickerState extends State<StickerGifPicker>
    with SingleTickerProviderStateMixin {
  late TabController _tabController;
  final searchController = TextEditingController();
  String selectedStickerCategory = 'Expressions';
  String selectedGifCategory = 'Trending';

  static const stickerCategories = ['Expressions', 'Celebrations', 'Reactions', 'Animals'];

  static const stickers = <StickerItem>[
    // Expressions
    StickerItem(id: 's_cool', emoji: '😎', title: 'Cool', category: 'Expressions'),
    StickerItem(id: 's_love', emoji: '😍', title: 'Love', category: 'Expressions'),
    StickerItem(id: 's_party', emoji: '🥳', title: 'Party', category: 'Expressions'),
    StickerItem(id: 's_think', emoji: '🤔', title: 'Thinking', category: 'Expressions'),
    StickerItem(id: 's_star', emoji: '🤩', title: 'Star', category: 'Expressions'),
    StickerItem(id: 's_mindblown', emoji: '🤯', title: 'Mind Blown', category: 'Expressions'),
    StickerItem(id: 's_innocent', emoji: '😇', title: 'Angel', category: 'Expressions'),
    StickerItem(id: 's_sleepy', emoji: '😴', title: 'Sleepy', category: 'Expressions'),
    StickerItem(id: 's_cowboy', emoji: '🤠', title: 'Cowboy', category: 'Expressions'),
    StickerItem(id: 's_robot', emoji: '🤖', title: 'Robot', category: 'Expressions'),
    StickerItem(id: 's_ghost', emoji: '👻', title: 'Ghost', category: 'Expressions'),
    StickerItem(id: 's_plead', emoji: '🥺', title: 'Please', category: 'Expressions'),

    // Celebrations
    StickerItem(id: 's_heart', emoji: '❤️', title: 'Red Heart', category: 'Celebrations'),
    StickerItem(id: 's_fire', emoji: '🔥', title: 'Fire', category: 'Celebrations'),
    StickerItem(id: 's_tada', emoji: '🎉', title: 'Tada', category: 'Celebrations'),
    StickerItem(id: 's_hundred', emoji: '💯', title: '100', category: 'Celebrations'),
    StickerItem(id: 's_sparkles', emoji: '✨', title: 'Sparkles', category: 'Celebrations'),
    StickerItem(id: 's_rocket', emoji: '🚀', title: 'Rocket', category: 'Celebrations'),
    StickerItem(id: 's_trophy', emoji: '🏆', title: 'Trophy', category: 'Celebrations'),
    StickerItem(id: 's_cake', emoji: '🎂', title: 'Birthday Cake', category: 'Celebrations'),
    StickerItem(id: 's_clink', emoji: '🥂', title: 'Cheers', category: 'Celebrations'),
    StickerItem(id: 's_pizza', emoji: '🍕', title: 'Pizza', category: 'Celebrations'),

    // Reactions
    StickerItem(id: 's_thumbup', emoji: '👍', title: 'Thumbs Up', category: 'Reactions'),
    StickerItem(id: 's_clap', emoji: '👏', title: 'Clap', category: 'Reactions'),
    StickerItem(id: 's_raised', emoji: '🙌', title: 'Celebration', category: 'Reactions'),
    StickerItem(id: 's_shake', emoji: '🤝', title: 'Handshake', category: 'Reactions'),
    StickerItem(id: 's_peace', emoji: '✌️', title: 'Peace', category: 'Reactions'),
    StickerItem(id: 's_pray', emoji: '🙏', title: 'Thank you', category: 'Reactions'),
    StickerItem(id: 's_salute', emoji: '🫡', title: 'Salute', category: 'Reactions'),
    StickerItem(id: 's_eyes', emoji: '👀', title: 'Looking', category: 'Reactions'),
    StickerItem(id: 's_zap', emoji: '⚡', title: 'Lightning', category: 'Reactions'),
    StickerItem(id: 's_ok', emoji: '👌', title: 'OK', category: 'Reactions'),

    // Animals
    StickerItem(id: 's_dog', emoji: '🐶', title: 'Puppy', category: 'Animals'),
    StickerItem(id: 's_cat', emoji: '🐱', title: 'Kitty', category: 'Animals'),
    StickerItem(id: 's_panda', emoji: '🐼', title: 'Panda', category: 'Animals'),
    StickerItem(id: 's_lion', emoji: '🦁', title: 'Lion', category: 'Animals'),
    StickerItem(id: 's_fox', emoji: '🦊', title: 'Fox', category: 'Animals'),
    StickerItem(id: 's_koala', emoji: '🐨', title: 'Koala', category: 'Animals'),
    StickerItem(id: 's_tiger', emoji: '🐯', title: 'Tiger', category: 'Animals'),
    StickerItem(id: 's_unicorn', emoji: '🦄', title: 'Unicorn', category: 'Animals'),
  ];

  static const gifCategories = ['Trending', 'Thumbs Up', 'Cheers', 'Laughing', 'Dance'];

  static const sampleGifs = <GifItem>[
    GifItem(
      id: 'g_celebrate',
      url: 'https://media.giphy.com/media/artj92V8o75VPL7AeQ/giphy.gif',
      title: 'Celebration Confetti',
      category: 'Trending',
    ),
    GifItem(
      id: 'g_thumbs_up',
      url: 'https://media.giphy.com/media/111ebonMs90YLu/giphy.gif',
      title: 'Thumbs Up Approval',
      category: 'Thumbs Up',
    ),
    GifItem(
      id: 'g_cheers',
      url: 'https://media.giphy.com/media/GCLlQnV7dXZ2E/giphy.gif',
      title: 'Cheers Toast',
      category: 'Cheers',
    ),
    GifItem(
      id: 'g_laugh',
      url: 'https://media.giphy.com/media/3oEjHAUOqG3lSS0f1C/giphy.gif',
      title: 'Laughing Out Loud',
      category: 'Laughing',
    ),
    GifItem(
      id: 'g_dance',
      url: 'https://media.giphy.com/media/blSTtZehjAZ8I/giphy.gif',
      title: 'Happy Dance',
      category: 'Dance',
    ),
  ];

  @override
  void initState() {
    super.initState();
    _tabController = TabController(length: 2, vsync: this);
  }

  @override
  void dispose() {
    _tabController.dispose();
    searchController.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return SizedBox(
      height: 380,
      child: Column(
        children: [
          TabBar(
            controller: _tabController,
            labelColor: theme.colorScheme.primary,
            indicatorColor: theme.colorScheme.primary,
            tabs: const [
              Tab(icon: Icon(Icons.sticky_note_2_outlined), text: 'Stickers'),
              Tab(icon: Icon(Icons.gif_box_outlined), text: 'GIFs'),
            ],
          ),
          Expanded(
            child: TabBarView(
              controller: _tabController,
              children: [
                _buildStickersTab(),
                _buildGifsTab(),
              ],
            ),
          ),
        ],
      ),
    );
  }

  Widget _buildStickersTab() {
    final filtered = stickers.where((s) => s.category == selectedStickerCategory).toList();
    return Column(
      children: [
        SingleChildScrollView(
          scrollDirection: Axis.horizontal,
          padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 8),
          child: Row(
            children: [
              for (final cat in stickerCategories)
                Padding(
                  padding: const EdgeInsets.only(right: 8),
                  child: FilterChip(
                    label: Text(cat),
                    selected: selectedStickerCategory == cat,
                    onSelected: (selected) {
                      if (selected) setState(() => selectedStickerCategory = cat);
                    },
                  ),
                ),
            ],
          ),
        ),
        Expanded(
          child: GridView.builder(
            padding: const EdgeInsets.all(12),
            gridDelegate: const SliverGridDelegateWithFixedCrossAxisCount(
              crossAxisCount: 4,
              mainAxisSpacing: 10,
              crossAxisSpacing: 10,
              childAspectRatio: 1.0,
            ),
            itemCount: filtered.length,
            itemBuilder: (context, i) {
              final sticker = filtered[i];
              return InkWell(
                borderRadius: BorderRadius.circular(16),
                onTap: () {
                  Navigator.pop(context);
                  widget.onSelectSticker({
                    'id': sticker.id,
                    'emoji': sticker.emoji,
                    'title': sticker.title,
                    'category': sticker.category,
                  });
                },
                child: Container(
                  decoration: BoxDecoration(
                    color: Theme.of(context).colorScheme.surfaceContainerHighest.withValues(alpha: 0.4),
                    borderRadius: BorderRadius.circular(16),
                  ),
                  alignment: Alignment.center,
                  child: Text(
                    sticker.emoji,
                    style: const TextStyle(fontSize: 42),
                  ),
                ),
              );
            },
          ),
        ),
      ],
    );
  }

  Widget _buildGifsTab() {
    final filtered = sampleGifs.where((g) => g.category == selectedGifCategory).toList();
    return Column(
      children: [
        Padding(
          padding: const EdgeInsets.fromLTRB(12, 8, 12, 4),
          child: Row(
            children: [
              Expanded(
                child: TextField(
                  controller: searchController,
                  decoration: InputDecoration(
                    hintText: 'Paste GIF URL or search...',
                    prefixIcon: const Icon(Icons.search, size: 20),
                    isDense: true,
                    border: OutlineInputBorder(borderRadius: BorderRadius.circular(20)),
                  ),
                  onSubmitted: (url) {
                    final trimmed = url.trim();
                    if (trimmed.isNotEmpty) {
                      Navigator.pop(context);
                      widget.onSelectGif({
                        'id': 'custom_gif_${DateTime.now().millisecondsSinceEpoch}',
                        'url': trimmed,
                        'title': 'GIF',
                      });
                    }
                  },
                ),
              ),
              const SizedBox(width: 8),
              IconButton.filledTonal(
                icon: const Icon(Icons.send, size: 18),
                onPressed: () {
                  final trimmed = searchController.text.trim();
                  if (trimmed.isNotEmpty) {
                    Navigator.pop(context);
                    widget.onSelectGif({
                      'id': 'custom_gif_${DateTime.now().millisecondsSinceEpoch}',
                      'url': trimmed,
                      'title': 'GIF',
                    });
                  }
                },
              ),
            ],
          ),
        ),
        SingleChildScrollView(
          scrollDirection: Axis.horizontal,
          padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 4),
          child: Row(
            children: [
              for (final cat in gifCategories)
                Padding(
                  padding: const EdgeInsets.only(right: 8),
                  child: FilterChip(
                    label: Text(cat),
                    selected: selectedGifCategory == cat,
                    onSelected: (selected) {
                      if (selected) setState(() => selectedGifCategory = cat);
                    },
                  ),
                ),
            ],
          ),
        ),
        Expanded(
          child: GridView.builder(
            padding: const EdgeInsets.all(12),
            gridDelegate: const SliverGridDelegateWithFixedCrossAxisCount(
              crossAxisCount: 2,
              mainAxisSpacing: 10,
              crossAxisSpacing: 10,
              childAspectRatio: 1.3,
            ),
            itemCount: filtered.length,
            itemBuilder: (context, i) {
              final gif = filtered[i];
              return InkWell(
                borderRadius: BorderRadius.circular(12),
                onTap: () {
                  Navigator.pop(context);
                  widget.onSelectGif({
                    'id': gif.id,
                    'url': gif.url,
                    'title': gif.title,
                  });
                },
                child: ClipRRect(
                  borderRadius: BorderRadius.circular(12),
                  child: Stack(
                    fit: StackFit.expand,
                    children: [
                      Image.network(
                        gif.url,
                        fit: BoxFit.cover,
                        errorBuilder: (_, _, _) => Container(
                          color: Colors.grey.shade800,
                          child: const Center(
                            child: Icon(Icons.gif, size: 40, color: Colors.white70),
                          ),
                        ),
                      ),
                      Positioned(
                        bottom: 0,
                        left: 0,
                        right: 0,
                        child: Container(
                          padding: const EdgeInsets.symmetric(vertical: 4, horizontal: 8),
                          color: Colors.black54,
                          child: Text(
                            gif.title,
                            style: const TextStyle(color: Colors.white, fontSize: 11),
                            maxLines: 1,
                            overflow: TextOverflow.ellipsis,
                          ),
                        ),
                      ),
                    ],
                  ),
                ),
              );
            },
          ),
        ),
      ],
    );
  }
}
