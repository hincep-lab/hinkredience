import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';

import '../../app/providers.dart';
import '../../app/router.dart';
import '../../core/app_colors.dart';
import '../../core/material.dart';
import '../../core/widgets.dart';
import '../../data/ai_models.dart';
import '../../data/recipe.dart';
import 'ai_common.dart';
import 'draft_review_screen.dart';

/// Chat s AI kuchařem. Konverzace se ukládá na serveru, takže se k ní
/// dá vrátit; AI při odpovědi vychází z uložených preferencí a vybavení.
class AiChatScreen extends ConsumerStatefulWidget {
  const AiChatScreen({
    super.key,
    this.conversationId,
    this.recipeId,
    this.draft,
  });

  /// Pokračování uložené konverzace.
  final String? conversationId;

  /// Recept, který se k první zprávě přiloží.
  final String? recipeId;

  /// Předvyplněná zpráva (uživatel ji sám odešle).
  final String? draft;

  @override
  ConsumerState<AiChatScreen> createState() => _AiChatScreenState();
}

class _AiChatScreenState extends ConsumerState<AiChatScreen> {
  final _input = TextEditingController();
  final _scroll = ScrollController();
  final _messages = <AiMessage>[];

  String? _conversationId;
  String? _photoBase64;
  bool _attachRecipe = false;
  bool _sending = false;
  bool _loadingHistory = false;
  Object? _error;
  String? _failedText;

  @override
  void initState() {
    super.initState();
    _conversationId = widget.conversationId;
    _attachRecipe = widget.recipeId != null;
    if (widget.draft != null) _input.text = widget.draft!;
    if (_conversationId != null) _loadHistory();
  }

  @override
  void dispose() {
    _input.dispose();
    _scroll.dispose();
    super.dispose();
  }

  Recipe? get _recipe {
    final id = widget.recipeId;
    if (id == null) return null;
    return ref.read(recipeProvider(id)).value;
  }

  Future<void> _loadHistory() async {
    final store = ref.read(aiHistoryStoreProvider);
    final id = _conversationId;
    if (store == null || id == null) return;
    setState(() => _loadingHistory = true);
    try {
      final messages = await store.messages(id);
      if (!mounted) return;
      setState(() {
        _messages
          ..clear()
          ..addAll(messages);
        _loadingHistory = false;
      });
      _scrollToEnd();
    } catch (error) {
      if (!mounted) return;
      setState(() {
        _loadingHistory = false;
        _error = AiException('Konverzaci se nepodařilo načíst: $error');
      });
    }
  }

  void _scrollToEnd() {
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (!_scroll.hasClients) return;
      _scroll.animateTo(
        _scroll.position.maxScrollExtent,
        duration: const Duration(milliseconds: 250),
        curve: Curves.easeOut,
      );
    });
  }

  Future<void> _send([String? preset]) async {
    final service = ref.read(aiServiceProvider);
    final text = (preset ?? _input.text).trim();
    final photo = _photoBase64;
    if (service == null || _sending || (text.isEmpty && photo == null)) return;

    final recipe = _attachRecipe ? _recipe : null;
    FocusScope.of(context).unfocus();
    setState(() {
      _sending = true;
      _error = null;
      _failedText = null;
      _messages.add(
        AiMessage(
          fromUser: true,
          text: text.isEmpty ? '(fotografie)' : text,
          hadPhoto: photo != null,
          attachedRecipeTitle: recipe?.title,
        ),
      );
      _input.clear();
      _photoBase64 = null;
    });
    _scrollToEnd();

    try {
      final reply = await service.chat(
        message: text,
        conversationId: _conversationId,
        recipe: recipe,
        imageBase64: photo,
      );
      if (!mounted) return;
      setState(() {
        _sending = false;
        _attachRecipe = false;
        if (reply.conversationId.isNotEmpty) {
          _conversationId = reply.conversationId;
        }
        _messages.add(
          AiMessage(
            fromUser: false,
            text: reply.reply,
            proposal: reply.recipe,
            changeSummary: reply.changeSummary,
            sources: reply.sources,
          ),
        );
      });
      ref.invalidate(aiConversationsProvider);
      _scrollToEnd();
    } catch (error) {
      if (!mounted) return;
      setState(() {
        _sending = false;
        _error = error;
        _failedText = text;
        // Neodeslaná zpráva se vrátí do pole, aby o ni uživatel nepřišel.
        _messages.removeLast();
        _input.text = text;
        _photoBase64 = photo;
      });
    }
  }

  Future<void> _addPhoto() async {
    final photo = await choosePhotoForAi(context);
    if (photo == null || !mounted) return;
    setState(() => _photoBase64 = photo);
  }

  void _openProposal(AiMessage message) {
    final draft = message.proposal;
    if (draft == null) return;
    final recipeId = widget.recipeId;
    context.push(
      Routes.draft,
      extra: DraftReviewArgs(
        proposal: DraftProposal(
          recipe: draft,
          summary: message.changeSummary,
          sources: message.sources,
        ),
        targetRecipeId: recipeId,
        heading: recipeId == null ? 'Návrh receptu' : 'Návrh úpravy',
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    final service = ref.watch(aiServiceProvider);
    final recipeId = widget.recipeId;
    final recipe = recipeId == null
        ? null
        : ref.watch(recipeProvider(recipeId)).value;

    return Scaffold(
      appBar: AppBar(
        title: const Text('AI kuchař'),
        actions: [
          if (service != null) ...[
            IconButton(
              tooltip: 'Nový rozhovor',
              icon: const Icon(Icons.add_comment_outlined),
              onPressed: () => context.pushReplacement(Routes.ai),
            ),
            IconButton(
              tooltip: 'Uložené rozhovory',
              icon: const Icon(Icons.history_rounded),
              onPressed: () => context.push(Routes.aiHistory),
            ),
          ],
        ],
      ),
      body: service == null
          ? const AiUnavailable()
          : SafeArea(
              child: Column(
                children: [
                  Expanded(child: _conversation(context, recipe)),
                  if (_photoBase64 != null || (_attachRecipe && recipe != null))
                    _Attachments(
                      recipeTitle: _attachRecipe ? recipe?.title : null,
                      hasPhoto: _photoBase64 != null,
                      onRemoveRecipe: () =>
                          setState(() => _attachRecipe = false),
                      onRemovePhoto: () => setState(() => _photoBase64 = null),
                    ),
                  _composer(),
                ],
              ),
            ),
    );
  }

  Widget _conversation(BuildContext context, Recipe? recipe) {
    if (_loadingHistory) {
      return const Center(child: CircularProgressIndicator());
    }
    final error = _error;
    final empty = _messages.isEmpty && !_sending;
    return ListView(
      controller: _scroll,
      padding: const EdgeInsets.fromLTRB(16, 12, 16, 12),
      children: [
        if (empty) _Welcome(recipe: recipe, onPick: _send),
        for (final message in _messages)
          _Bubble(
            message: message,
            onOpenProposal: () => _openProposal(message),
          ),
        if (_sending) const _Typing(),
        if (error != null)
          Padding(
            padding: const EdgeInsets.only(top: 8),
            child: AiErrorCard(
              error: error,
              onRetry: _failedText == null ? null : () => _send(),
            ),
          ),
      ],
    );
  }

  Widget _composer() {
    return Padding(
      padding: const EdgeInsets.fromLTRB(12, 4, 12, 10),
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.end,
        children: [
          IconButton(
            tooltip: 'Přiložit fotografii',
            icon: const Icon(Icons.add_a_photo_outlined),
            onPressed: _sending ? null : _addPhoto,
          ),
          Expanded(
            child: TextField(
              controller: _input,
              minLines: 1,
              maxLines: 5,
              textCapitalization: TextCapitalization.sentences,
              decoration: InputDecoration(
                hintText: 'Napiš mi, co tě zajímá…',
                contentPadding: const EdgeInsets.symmetric(
                  horizontal: 18,
                  vertical: 12,
                ),
                border: OutlineInputBorder(
                  borderRadius: BorderRadius.circular(24),
                  borderSide: const BorderSide(color: AppColors.outline),
                ),
                enabledBorder: OutlineInputBorder(
                  borderRadius: BorderRadius.circular(24),
                  borderSide: const BorderSide(color: AppColors.outline),
                ),
                focusedBorder: OutlineInputBorder(
                  borderRadius: BorderRadius.circular(24),
                  borderSide: const BorderSide(
                    color: AppColors.copperGold,
                    width: 1.5,
                  ),
                ),
              ),
            ),
          ),
          const SizedBox(width: 6),
          IconButton.filled(
            tooltip: 'Odeslat',
            style: IconButton.styleFrom(
              backgroundColor: AppColors.copper,
              foregroundColor: const Color(0xFF1B1108),
            ),
            icon: const Icon(Icons.arrow_upward_rounded),
            onPressed: _sending ? null : () => _send(),
          ),
        ],
      ),
    );
  }
}

class _Welcome extends StatelessWidget {
  const _Welcome({required this.recipe, required this.onPick});

  final Recipe? recipe;
  final void Function(String text) onPick;

  @override
  Widget build(BuildContext context) {
    final prompts = recipe == null
        ? const [
            'Vymysli mi oběd z kuřete, co bude chutnat i dětem.',
            'Co uvařit na víkend v pomalém hrnci?',
            'Navrhni sous-vide steak s přesnými teplotami.',
            'Sestav jídelníček večeří na pět dní.',
          ]
        : const [
            'Uprav recept na dvojnásobek porcí.',
            'Zjednoduš postup.',
            'Přizpůsob recept mému vybavení.',
            'Čím nahradit suroviny, které doma nemám?',
            'Vytvoř nákupní seznam.',
          ];
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        const SizedBox(height: 8),
        const Center(
          child: Icon(
            Icons.auto_awesome_rounded,
            color: AppColors.copperGold,
            size: 40,
          ),
        ),
        const SizedBox(height: 10),
        Center(
          child: Text(
            'Tvůj kuchařský parťák s pamětí',
            style: Theme.of(context).textTheme.titleMedium,
          ),
        ),
        const SizedBox(height: 6),
        Text(
          recipe == null
              ? 'Zeptej se na cokoli kolem vaření. Recepty, které navrhnu, '
                    'si před uložením prohlédneš.'
              : 'K první zprávě přiložím recept „${recipe!.title}“. '
                    'Úpravy ti navrhnu, uložený recept sám nepřepíšu.',
          textAlign: TextAlign.center,
          style: const TextStyle(color: AppColors.textSecondary, height: 1.4),
        ),
        const SizedBox(height: 16),
        Wrap(
          spacing: 8,
          runSpacing: 8,
          children: [
            for (final prompt in prompts)
              ActionChip(label: Text(prompt), onPressed: () => onPick(prompt)),
          ],
        ),
      ],
    );
  }
}

class _Attachments extends StatelessWidget {
  const _Attachments({
    required this.recipeTitle,
    required this.hasPhoto,
    required this.onRemoveRecipe,
    required this.onRemovePhoto,
  });

  final String? recipeTitle;
  final bool hasPhoto;
  final VoidCallback onRemoveRecipe;
  final VoidCallback onRemovePhoto;

  @override
  Widget build(BuildContext context) {
    return Padding(
      padding: const EdgeInsets.fromLTRB(16, 0, 16, 2),
      child: Align(
        alignment: Alignment.centerLeft,
        child: Wrap(
          spacing: 8,
          children: [
            if (recipeTitle != null)
              InputChip(
                avatar: const Icon(Icons.menu_book_rounded, size: 18),
                label: Text(recipeTitle!),
                onDeleted: onRemoveRecipe,
              ),
            if (hasPhoto)
              InputChip(
                avatar: const Icon(Icons.photo_outlined, size: 18),
                label: const Text('Fotografie'),
                onDeleted: onRemovePhoto,
              ),
          ],
        ),
      ),
    );
  }
}

class _Typing extends StatelessWidget {
  const _Typing();

  @override
  Widget build(BuildContext context) {
    return const Padding(
      padding: EdgeInsets.symmetric(vertical: 10),
      child: Row(
        children: [
          SizedBox(
            width: 18,
            height: 18,
            child: CircularProgressIndicator(strokeWidth: 2.2),
          ),
          SizedBox(width: 12),
          Text(
            'AI kuchař přemýšlí…',
            style: TextStyle(color: AppColors.textSecondary),
          ),
        ],
      ),
    );
  }
}

class _Bubble extends StatelessWidget {
  const _Bubble({required this.message, required this.onOpenProposal});

  final AiMessage message;
  final VoidCallback onOpenProposal;

  @override
  Widget build(BuildContext context) {
    final mine = message.fromUser;
    final proposal = message.proposal;
    final attachedTitle = message.attachedRecipeTitle;
    return Align(
      alignment: mine ? Alignment.centerRight : Alignment.centerLeft,
      child: ConstrainedBox(
        constraints: BoxConstraints(
          maxWidth: MediaQuery.sizeOf(context).width * 0.84,
        ),
        child: Container(
          margin: const EdgeInsets.symmetric(vertical: 5),
          padding: const EdgeInsets.fromLTRB(14, 10, 14, 10),
          decoration: BoxDecoration(
            color: mine ? const Color(0xFF3A2616) : AppColors.card,
            borderRadius: BorderRadius.only(
              topLeft: const Radius.circular(18),
              topRight: const Radius.circular(18),
              bottomLeft: Radius.circular(mine ? 18 : 4),
              bottomRight: Radius.circular(mine ? 4 : 18),
            ),
            border: Border.all(color: AppColors.outline),
          ),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              if (attachedTitle != null || message.hadPhoto)
                Padding(
                  padding: const EdgeInsets.only(bottom: 4),
                  child: Text(
                    [
                      if (attachedTitle != null) 'Recept: $attachedTitle',
                      if (message.hadPhoto) 'Fotografie',
                    ].join(' · '),
                    style: const TextStyle(
                      color: AppColors.copperGold,
                      fontSize: 12,
                    ),
                  ),
                ),
              Text(
                message.text,
                style: const TextStyle(height: 1.4, fontSize: 15),
              ),
              if (proposal != null) ...[
                const SizedBox(height: 10),
                HkCard(
                  onTap: onOpenProposal,
                  padding: const EdgeInsets.all(12),
                  child: Row(
                    children: [
                      const Icon(
                        Icons.restaurant_menu_rounded,
                        color: AppColors.copperGold,
                      ),
                      const SizedBox(width: 10),
                      Expanded(
                        child: Column(
                          crossAxisAlignment: CrossAxisAlignment.start,
                          children: [
                            Text(
                              proposal.title,
                              maxLines: 2,
                              overflow: TextOverflow.ellipsis,
                              style: const TextStyle(
                                fontWeight: FontWeight.w700,
                              ),
                            ),
                            Text(
                              '${proposal.ingredients.length} surovin · '
                              '${proposal.steps.length} kroků · prohlédnout a uložit',
                              style: const TextStyle(
                                color: AppColors.textSecondary,
                                fontSize: 12.5,
                              ),
                            ),
                          ],
                        ),
                      ),
                      const Icon(
                        Icons.chevron_right_rounded,
                        color: AppColors.textSecondary,
                      ),
                    ],
                  ),
                ),
              ],
              if (message.sources.isNotEmpty) ...[
                const SizedBox(height: 8),
                SourceLinks(sources: message.sources),
              ],
            ],
          ),
        ),
      ),
    );
  }
}
