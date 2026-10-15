/// Compile-time local artwork/content for Phase 1 UI previews only. Nothing in
/// this library reads, writes or impersonates Supabase data.
class PreviewMessage {
  const PreviewMessage(this.text, this.time, {this.own = false});
  final String text, time;
  final bool own;
}

class PreviewConversation {
  const PreviewConversation({
    required this.id,
    required this.name,
    required this.subtitle,
    required this.color,
    required this.messages,
    this.unread = 0,
    this.group = false,
  });
  final String id, name, subtitle;
  final int color, unread;
  final bool group;
  final List<PreviewMessage> messages;
}

const previewConversations = [
  PreviewConversation(
    id: 'maya',
    name: 'Maya Chen',
    subtitle: 'A little inspiration for the weekend',
    color: 0xffba6c51,
    unread: 2,
    messages: [
      PreviewMessage('A little inspiration for the weekend ☀️', '10:24'),
      PreviewMessage(
        'Let’s take the coast road and find a quiet café.',
        '10:25',
      ),
      PreviewMessage('Sounds like a lovely plan.', '10:26', own: true),
      PreviewMessage(
        'These are local preview messages. Real conversations arrive in Phase 2.',
        '10:27',
      ),
    ],
  ),
  PreviewConversation(
    id: 'arjun',
    name: 'Arjun Patel',
    subtitle: 'The new design feels great.',
    color: 0xff597caa,
    messages: [
      PreviewMessage('The new design feels great.', '09:41'),
      PreviewMessage(
        'I’m trying out the chat layout today.',
        '09:42',
        own: true,
      ),
    ],
  ),
  PreviewConversation(
    id: 'weekend',
    name: 'Weekend people',
    subtitle: 'Sofia: Who’s bringing the playlist?',
    color: 0xff7b709e,
    unread: 3,
    group: true,
    messages: [
      PreviewMessage('Sofia: Who’s bringing the playlist?', 'Yesterday'),
      PreviewMessage('I have a few ideas 🎶', 'Yesterday', own: true),
    ],
  ),
  PreviewConversation(
    id: 'studio',
    name: 'Studio circle',
    subtitle: 'A place to share ideas',
    color: 0xff578477,
    group: true,
    messages: [PreviewMessage('A place to share ideas', 'Yesterday')],
  ),
];

PreviewConversation? previewConversation(String id) {
  for (final conversation in previewConversations) {
    if (conversation.id == id) return conversation;
  }
  return null;
}
