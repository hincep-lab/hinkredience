import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';

import '../../app/providers.dart';
import '../../app/router.dart';
import '../../core/app_colors.dart';
import '../../core/formatters.dart';
import '../../core/material.dart';
import '../../core/widgets.dart';
import '../../data/ai_models.dart';
import 'ai_common.dart';

/// Uložené rozhovory s AI kuchařem.
class AiHistoryScreen extends ConsumerWidget {
  const AiHistoryScreen({super.key});

  Future<void> _delete(
    BuildContext context,
    WidgetRef ref,
    AiConversation conversation,
  ) async {
    final confirmed = await confirm(
      context,
      title: 'Smazat rozhovor?',
      message: '„${conversation.title}“ se smaže natrvalo.',
      confirmLabel: 'Smazat',
      destructive: true,
    );
    if (!confirmed) return;
    try {
      await ref.read(aiHistoryStoreProvider)?.delete(conversation.id);
      ref.invalidate(aiConversationsProvider);
    } catch (error) {
      if (context.mounted) {
        showMessage(context, 'Rozhovor se nepodařilo smazat: $error');
      }
    }
  }

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final available = ref.watch(aiServiceProvider) != null;
    final conversations = ref.watch(aiConversationsProvider);

    return Scaffold(
      appBar: AppBar(title: const Text('Uložené rozhovory')),
      body: !available
          ? const AiUnavailable()
          : conversations.when(
              loading: () => const Center(child: CircularProgressIndicator()),
              error: (error, stack) => ErrorState(
                error: error,
                onRetry: () => ref.invalidate(aiConversationsProvider),
              ),
              data: (list) => list.isEmpty
                  ? const EmptyState(
                      icon: Icons.forum_outlined,
                      title: 'Zatím žádné rozhovory',
                      message:
                          'Každý rozhovor s AI kuchařem se uloží, abyste se '
                          'k němu mohli vrátit.',
                    )
                  : ListView.separated(
                      padding: const EdgeInsets.fromLTRB(16, 8, 16, 24),
                      itemCount: list.length,
                      separatorBuilder: (context, index) =>
                          const SizedBox(height: 8),
                      itemBuilder: (context, index) {
                        final conversation = list[index];
                        return HkCard(
                          padding: const EdgeInsets.fromLTRB(16, 6, 4, 6),
                          onTap: () => context.push(
                            Routes.aiChat(conversationId: conversation.id),
                          ),
                          child: Row(
                            children: [
                              const Icon(
                                Icons.chat_bubble_outline_rounded,
                                color: AppColors.copperGold,
                              ),
                              const SizedBox(width: 12),
                              Expanded(
                                child: Column(
                                  crossAxisAlignment: CrossAxisAlignment.start,
                                  children: [
                                    Text(
                                      conversation.title,
                                      maxLines: 2,
                                      overflow: TextOverflow.ellipsis,
                                      style: const TextStyle(
                                        fontWeight: FontWeight.w600,
                                      ),
                                    ),
                                    Text(
                                      formatDate(conversation.updatedAt),
                                      style: const TextStyle(
                                        color: AppColors.textSecondary,
                                        fontSize: 12.5,
                                      ),
                                    ),
                                  ],
                                ),
                              ),
                              IconButton(
                                tooltip: 'Smazat rozhovor',
                                icon: const Icon(Icons.delete_outline_rounded),
                                onPressed: () =>
                                    _delete(context, ref, conversation),
                              ),
                            ],
                          ),
                        );
                      },
                    ),
            ),
    );
  }
}
