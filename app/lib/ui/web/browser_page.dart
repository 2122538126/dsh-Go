import 'dart:async';

import 'package:flutter/material.dart';
import 'package:webview_flutter/webview_flutter.dart';

import '../../l10n/l10n.dart';
import '../shell/page_frame.dart';
import '../theme/app_icons.dart';
import 'web_file_chooser.dart';
import 'web_view_guard.dart';

/// A browser in the app: one page per tab, an address bar over it and a tab
/// strip under it.
///
/// The shell keeps this mounted and only hides it ([browserVisibleProvider]),
/// so leaving for the chat keeps every tab's page — scroll position, forms,
/// running scripts — and coming back costs nothing. Back presses reach it
/// through [BrowserPageState.handleBack]. Its WebViews go through
/// [WebViewGuard] like every other one: a crashed renderer closes this
/// browser's pages, not the app.
class BrowserPage extends StatefulWidget {
  const BrowserPage({super.key, this.initialUrl, required this.onLeave});

  /// Opened on this address instead of the start page.
  final String? initialUrl;

  /// Back found nothing left to do here: the host hides the browser and shows
  /// the chat again.
  final VoidCallback onLeave;

  @override
  State<BrowserPage> createState() => BrowserPageState();
}

class BrowserPageState extends State<BrowserPage> {
  final List<_BrowserTab> _tabs = [];
  int _active = 0;

  /// The address bar's own field, reused for every edit. The node is never
  /// disposed from inside its own focus callback (that is what froze the page
  /// when back left the bar).
  final _address = TextEditingController();
  final _addressFocus = FocusNode();
  bool _editing = false;

  /// The app's look, read once per build of the tree rather than in
  /// [initState] where there is no [Theme] yet.
  bool _dark = false;
  int _textZoom = 100;

  _BrowserTab? get _tab => _active >= 0 && _active < _tabs.length ? _tabs[_active] : null;

  @override
  void initState() {
    super.initState();
    _addressFocus.addListener(_onAddressFocus);
    _addTab();
    final start = widget.initialUrl;
    if (start != null && start.trim().isNotEmpty) {
      // After the first frame: a load in initState would setState while the
      // tree is still being built.
      WidgetsBinding.instance.addPostFrameCallback((_) {
        final tab = _tabs.firstOrNull;
        if (mounted && tab != null) unawaited(_open(tab, start));
      });
    }
  }

  @override
  void didChangeDependencies() {
    super.didChangeDependencies();
    _dark = Theme.of(context).brightness == Brightness.dark;
    _textZoom = MediaQuery.textScalerOf(context).scale(100).round().clamp(50, 300);
  }

  @override
  void dispose() {
    for (final tab in _tabs) {
      tab.guard.dispose();
      unawaited(tab.guard.destroy());
    }
    _address.dispose();
    _addressFocus.dispose();
    super.dispose();
  }

  void _addTab() {
    setState(() {
      _tabs.add(_BrowserTab(onChanged: () => setState(() {})));
      _active = _tabs.length - 1;
    });
  }

  void _selectTab(int index) => setState(() => _active = index.clamp(0, _tabs.length - 1));

  void _closeTab(int index) {
    if (index < 0 || index >= _tabs.length) return;
    final tab = _tabs.removeAt(index);
    tab.guard.dispose();
    unawaited(tab.guard.destroy());
    setState(() => _active = _tabs.isEmpty ? 0 : _active.clamp(0, _tabs.length - 1));
  }

  /// A new WebView for [tab], landing on [target].
  Future<void> _open(_BrowserTab tab, String target) async {
    final url = _normalize(target);
    final previous = tab.controller;
    tab
      ..generation += 1
      ..url = url
      ..title = ''
      ..progress = 0
      ..loading = true
      ..error = null
      ..gone = false
      ..canGoBack = false
      ..canGoForward = false;
    if (mounted) setState(() {});
    if (previous != null) unawaited(tab.guard.destroy());
    tab.files.invalidate();

    final controller = WebViewController();
    tab.controller = controller;
    await Future.wait(
      [
        controller.setJavaScriptMode(JavaScriptMode.unrestricted),
        tab.files.attach(controller),
        controller.setNavigationDelegate(
          NavigationDelegate(
            onPageStarted: (_) {
              if (!mounted || tab.controller != controller) return;
              tab.files.invalidate();
              tab
                ..loading = true
                ..progress = 0
                ..error = null;
              if (mounted) setState(() {});
            },
            onProgress: (progress) {
              if (!mounted || tab.controller != controller) return;
              tab.progress = progress;
              if (mounted) setState(() {});
            },
            onUrlChange: (change) {
              if (!mounted || tab.controller != controller) return;
              final url = change.url;
              if (url == null || url.isEmpty) return;
              tab.url = url;
              if (mounted) setState(() {});
            },
            onPageFinished: (url) {
              if (!mounted || tab.controller != controller) return;
              tab
                ..loading = false
                ..progress = 100
                ..url = url;
              unawaited(_refreshHistory(tab, controller));
              unawaited(_readTitle(tab, controller));
              if (mounted) setState(() {});
            },
            onWebResourceError: (error) {
              if (!mounted || tab.controller != controller) return;
              if (!(error.isForMainFrame ?? true)) return;
              tab
                ..loading = false
                ..error = error.description;
              if (mounted) setState(() {});
            },
          ),
        ),
      ].map((future) => future.catchError((_) {})),
    );
    if (!mounted || tab.controller != controller) return;
    // After the navigation delegate: the guard wraps the client it set.
    await tab.guard.attach(controller, dark: _dark, textZoom: _textZoom);
    if (!mounted || tab.controller != controller) return;
    await controller.loadRequest(Uri.parse(url)).catchError((_) {});
  }

  Future<void> _refreshHistory(_BrowserTab tab, WebViewController controller) async {
    try {
      final back = await controller.canGoBack();
      final forward = await controller.canGoForward();
      if (!mounted || tab.controller != controller) return;
      tab
        ..canGoBack = back
        ..canGoForward = forward;
      if (mounted) setState(() {});
    } catch (_) {}
  }

  Future<void> _readTitle(_BrowserTab tab, WebViewController controller) async {
    String? title;
    try {
      title = await controller.getTitle();
    } catch (_) {
      return;
    }
    if (!mounted || tab.controller != controller) return;
    tab.title = title?.trim() ?? '';
    if (mounted) setState(() {});
  }

  void _editAddress() {
    final text = _tab?.url ?? '';
    _address
      ..text = text
      ..selection = TextSelection(baseOffset: 0, extentOffset: text.length);
    setState(() => _editing = true);
    _addressFocus.requestFocus();
  }

  /// The field lost focus (a tap on the page, or back leaving the bar): show
  /// the address again. The node stays alive — disposing it here would run
  /// inside its own listener.
  void _onAddressFocus() {
    if (_addressFocus.hasFocus || !mounted || !_editing) return;
    setState(() => _editing = false);
  }

  void _leaveAddress() {
    if (!_editing) return;
    _addressFocus.unfocus();
    if (mounted) setState(() => _editing = false);
  }

  void _submitAddress(String value) {
    final tab = _tab;
    _leaveAddress();
    if (tab == null || value.trim().isEmpty) return;
    unawaited(_open(tab, value));
  }

  /// One press of back, in this order: leave the address bar, go back in the
  /// page, close a tab, and finally [BrowserPage.onLeave] — the chat again.
  ///
  /// The page is asked live rather than from the cached flag: a site that
  /// navigates with pushState never "finishes loading", so a cached
  /// `canGoBack` stays true and every press would re-run the same no-op.
  Future<void> handleBack() async {
    if (_editing) {
      _leaveAddress();
      return;
    }
    final current = _tab;
    final controller = current?.controller;
    if (current != null && controller != null && !current.gone) {
      var canGoBack = false;
      try {
        canGoBack = await controller.canGoBack();
      } catch (_) {}
      if (!mounted) return;
      if (canGoBack) {
        await controller.goBack().catchError((_) {});
        return;
      }
    }
    if (_tabs.length > 1) {
      _closeTab(_active);
      return;
    }
    if (mounted) widget.onLeave();
  }

  @override
  Widget build(BuildContext context) {
    final tab = _tab;
    final colors = Theme.of(context).colorScheme;
    final loading = tab?.loading ?? false;
    return Scaffold(
        backgroundColor: colors.surface,
        body: Column(
          children: [
            SafeArea(
              bottom: false,
              child: _AddressBar(
                url: tab?.url,
                loading: loading,
                editing: _editing ? _addressFocus : null,
                address: _address,
                onEdit: _editAddress,
                onSubmit: _submitAddress,
                onCancel: _leaveAddress,
                onBack: tab != null && tab.canGoBack ? () => unawaited(tab.controller?.goBack()) : null,
                onForward: tab != null && tab.canGoForward ? () => unawaited(tab.controller?.goForward()) : null,
                onReload: tab == null || tab.gone
                    ? null
                    // 停止 is the page's own window.stop(): the controller has
                    // no stop of its own.
                    : () => unawaited(
                        loading ? tab.controller?.runJavaScript('window.stop()') : tab.controller?.reload(),
                      ),
                onNewTab: _addTab,
              ),
            ),
            if (loading)
              LinearProgressIndicator(
                value: (tab?.progress ?? 0) <= 0 || (tab?.progress ?? 0) >= 100 ? null : (tab!.progress / 100),
                minHeight: 2,
                backgroundColor: Colors.transparent,
              ),
            Expanded(child: _pages()),
            _TabStrip(
              tabs: _tabs,
              active: _active,
              onSelect: _selectTab,
              onClose: _closeTab,
              onNew: _addTab,
            ),
          ],
        ),
    );
  }

  Widget _pages() {
    if (_tabs.isEmpty) return const SizedBox.shrink();
    return IndexedStack(
      index: _active.clamp(0, _tabs.length - 1),
      children: [for (final tab in _tabs) KeyedSubtree(key: ValueKey(tab.id), child: _page(tab))],
    );
  }

  Widget _page(_BrowserTab tab) {
    final controller = tab.controller;
    if (controller == null) return _StartPage(onOpen: (url) => unawaited(_open(tab, url)));
    if (tab.gone) return _Gone(onReopen: () => unawaited(_open(tab, tab.url ?? '')));
    if (tab.error case final error?) return _LoadError(detail: error, onRetry: () => unawaited(_open(tab, tab.url ?? '')));
    return WebViewWidget(key: ValueKey('${tab.id}-${tab.generation}'), controller: controller);
  }
}

/// One tab: its WebView and what the bar over it shows.
class _BrowserTab {
  _BrowserTab({required this.onChanged}) {
    guard = WebViewGuard(onGone: _onGone);
  }

  final VoidCallback onChanged;
  final int id = _nextId++;

  /// Made in the constructor body: its callback is this tab's own method.
  late final WebViewGuard guard;
  final WebFileChooser files = WebFileChooser();

  static int _nextId = 0;

  WebViewController? controller;
  String? url;
  String title = '';
  int progress = 0;
  int generation = 0;
  bool loading = false;
  bool canGoBack = false;
  bool canGoForward = false;
  bool gone = false;
  String? error;

  /// The renderer is gone: this page says so until it is reopened.
  void _onGone(bool crashed) {
    gone = true;
    loading = false;
    onChanged();
  }
}

/// The bar over the page: back · forward · the address · reload · new tab.
class _AddressBar extends StatelessWidget {
  const _AddressBar({
    required this.url,
    required this.loading,
    required this.editing,
    required this.address,
    required this.onEdit,
    required this.onSubmit,
    required this.onCancel,
    required this.onBack,
    required this.onForward,
    required this.onReload,
    required this.onNewTab,
  });

  final String? url;
  final bool loading;
  final FocusNode? editing;
  final TextEditingController? address;
  final VoidCallback onEdit;
  final ValueChanged<String> onSubmit;
  final VoidCallback onCancel;
  final VoidCallback? onBack;
  final VoidCallback? onForward;
  final VoidCallback? onReload;
  final VoidCallback onNewTab;

  @override
  Widget build(BuildContext context) {
    final l10n = context.l10n;
    final colors = Theme.of(context).colorScheme;
    final focus = editing;
    return Padding(
      padding: const EdgeInsets.fromLTRB(8, 6, 8, 6),
      child: Row(
        children: [
          GlassIconButton(
            icon: AppIcons.back,
            tooltip: l10n.browserBack,
            size: 36,
            iconSize: 18,
            onPressed: onBack,
          ),
          const SizedBox(width: 4),
          GlassIconButton(
            icon: AppIcons.forward,
            tooltip: l10n.browserForward,
            size: 36,
            iconSize: 18,
            onPressed: onForward,
          ),
          const SizedBox(width: 6),
          Expanded(
            child: focus == null
                ? _AddressLabel(url: url, onTap: onEdit)
                : TextField(
                    controller: address,
                    focusNode: focus,
                    autofocus: true,
                    textInputAction: TextInputAction.go,
                    keyboardType: TextInputType.url,
                    autocorrect: false,
                    enableSuggestions: false,
                    style: Theme.of(context).textTheme.bodyMedium,
                    decoration: InputDecoration(
                      isDense: true,
                      hintText: l10n.browserAddressHint,
                      filled: true,
                      fillColor: colors.surfaceContainerHighest,
                      contentPadding: const EdgeInsets.symmetric(horizontal: 12, vertical: 10),
                      border: OutlineInputBorder(
                        borderRadius: BorderRadius.circular(18),
                        borderSide: BorderSide.none,
                      ),
                    ),
                    onSubmitted: onSubmit,
                    onTapOutside: (_) => onCancel(),
                  ),
          ),
          const SizedBox(width: 4),
          GlassIconButton(
            icon: loading ? AppIcons.close : AppIcons.refresh,
            tooltip: loading ? l10n.browserStop : l10n.webRefresh,
            size: 36,
            iconSize: 18,
            onPressed: onReload,
          ),
          const SizedBox(width: 4),
          GlassIconButton(
            icon: AppIcons.add,
            tooltip: l10n.browserNewTab,
            size: 36,
            iconSize: 18,
            onPressed: onNewTab,
          ),
        ],
      ),
    );
  }
}

class _AddressLabel extends StatelessWidget {
  const _AddressLabel({required this.url, required this.onTap});

  final String? url;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    final colors = Theme.of(context).colorScheme;
    final empty = url == null || url!.isEmpty;
    final secure = url != null && url!.startsWith('https://');
    return InkWell(
      onTap: onTap,
      borderRadius: BorderRadius.circular(18),
      child: Container(
        height: 38,
        padding: const EdgeInsets.symmetric(horizontal: 12),
        decoration: BoxDecoration(color: colors.surfaceContainerHighest, borderRadius: BorderRadius.circular(18)),
        child: Row(
          children: [
            Icon(secure ? AppIcons.lock : AppIcons.web, size: 14, color: colors.onSurfaceVariant),
            const SizedBox(width: 6),
            Expanded(
              child: Text(
                empty ? context.l10n.browserAddressHint : url!,
                maxLines: 1,
                overflow: TextOverflow.ellipsis,
                style: Theme.of(context).textTheme.bodyMedium?.copyWith(color: colors.onSurfaceVariant),
              ),
            ),
          ],
        ),
      ),
    );
  }
}

/// The tabs, under the page. One tab needs no strip: the bar's 新建 covers it.
class _TabStrip extends StatelessWidget {
  const _TabStrip({
    required this.tabs,
    required this.active,
    required this.onSelect,
    required this.onClose,
    required this.onNew,
  });

  final List<_BrowserTab> tabs;
  final int active;
  final ValueChanged<int> onSelect;
  final ValueChanged<int> onClose;
  final VoidCallback onNew;

  @override
  Widget build(BuildContext context) {
    final padding = MediaQuery.paddingOf(context).bottom;
    final colors = Theme.of(context).colorScheme;
    if (tabs.length <= 1) return SizedBox(height: padding);
    return Container(
      height: 44 + padding,
      padding: EdgeInsets.only(bottom: padding),
      decoration: BoxDecoration(
        color: colors.surfaceContainer,
        border: Border(top: BorderSide(color: colors.outlineVariant, width: 0.5)),
      ),
      child: Row(
        children: [
          Expanded(
            child: ListView.builder(
              scrollDirection: Axis.horizontal,
              padding: const EdgeInsets.symmetric(horizontal: 6, vertical: 5),
              itemCount: tabs.length,
              itemBuilder: (context, index) {
                final tab = tabs[index];
                final selected = index == active;
                final label = tab.title.isNotEmpty ? tab.title : (tab.url ?? context.l10n.browserUntitled);
                return Padding(
                  padding: const EdgeInsets.only(right: 6),
                  child: InkWell(
                    onTap: () => onSelect(index),
                    borderRadius: BorderRadius.circular(14),
                    child: Container(
                      constraints: const BoxConstraints(maxWidth: 160),
                      padding: const EdgeInsets.only(left: 10),
                      decoration: BoxDecoration(
                        color: selected ? colors.surfaceContainerHighest : Colors.transparent,
                        borderRadius: BorderRadius.circular(14),
                      ),
                      child: Row(
                        mainAxisSize: MainAxisSize.min,
                        children: [
                          Flexible(
                            child: Text(
                              label,
                              maxLines: 1,
                              overflow: TextOverflow.ellipsis,
                              style: Theme.of(context).textTheme.bodySmall?.copyWith(
                                color: selected ? colors.onSurface : colors.onSurfaceVariant,
                              ),
                            ),
                          ),
                          InkWell(
                            onTap: () => onClose(index),
                            child: Padding(
                              padding: const EdgeInsets.all(6),
                              child: Icon(AppIcons.close, size: 13, color: colors.onSurfaceVariant),
                            ),
                          ),
                        ],
                      ),
                    ),
                  ),
                );
              },
            ),
          ),
          IconButton(
            onPressed: onNew,
            tooltip: context.l10n.browserNewTab,
            icon: const Icon(AppIcons.add, size: 18),
          ),
        ],
      ),
    );
  }
}

/// A tab that has not been anywhere yet.
class _StartPage extends StatelessWidget {
  const _StartPage({required this.onOpen});

  final ValueChanged<String> onOpen;

  static const _shortcuts = <(String, String)>[
    ('DeepSeek', 'https://chat.deepseek.com'),
    ('GitHub', 'https://github.com'),
    ('Bing', 'https://www.bing.com'),
    ('Wikipedia', 'https://www.wikipedia.org'),
  ];

  @override
  Widget build(BuildContext context) {
    final colors = Theme.of(context).colorScheme;
    return Center(
      child: Padding(
        padding: const EdgeInsets.all(24),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            Icon(AppIcons.web, size: 44, color: colors.onSurfaceVariant),
            const SizedBox(height: 14),
            Text(
              context.l10n.browserEmpty,
              textAlign: TextAlign.center,
              style: Theme.of(context).textTheme.bodyMedium?.copyWith(color: colors.onSurfaceVariant),
            ),
            const SizedBox(height: 18),
            Wrap(
              spacing: 10,
              runSpacing: 10,
              alignment: WrapAlignment.center,
              children: [
                for (final (name, url) in _shortcuts) ActionChip(label: Text(name), onPressed: () => onOpen(url)),
              ],
            ),
          ],
        ),
      ),
    );
  }
}

class _Gone extends StatelessWidget {
  const _Gone({required this.onReopen});

  final VoidCallback onReopen;

  @override
  Widget build(BuildContext context) {
    return Center(
      child: Column(
        mainAxisSize: MainAxisSize.min,
        children: [
          Text(context.l10n.webPageClosed),
          const SizedBox(height: 12),
          FilledButton(onPressed: onReopen, child: Text(context.l10n.webRefresh)),
        ],
      ),
    );
  }
}

class _LoadError extends StatelessWidget {
  const _LoadError({required this.detail, required this.onRetry});

  final String detail;
  final VoidCallback onRetry;

  @override
  Widget build(BuildContext context) {
    final colors = Theme.of(context).colorScheme;
    return Center(
      child: Padding(
        padding: const EdgeInsets.all(24),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            Text(context.l10n.browserLoadFailed),
            const SizedBox(height: 8),
            Text(
              detail,
              textAlign: TextAlign.center,
              style: Theme.of(context).textTheme.bodySmall?.copyWith(color: colors.onSurfaceVariant),
            ),
            const SizedBox(height: 16),
            FilledButton(onPressed: onRetry, child: Text(context.l10n.webRefresh)),
          ],
        ),
      ),
    );
  }
}

/// What a typed address means: a URL, or a search.
///
/// A bare word goes to the search engine; anything with a scheme of its own
/// (or with a dot in its first segment) is a host and gets `https://` when it
/// has none.
String _normalize(String input) {
  final text = input.trim();
  if (text.isEmpty) return 'about:blank';
  final parsed = Uri.tryParse(text);
  final scheme = parsed?.scheme.toLowerCase() ?? '';
  if (scheme == 'http' || scheme == 'https' || scheme == 'file' || scheme == 'about' || scheme == 'data') {
    return text;
  }
  if (_looksLikeHost(text)) return 'https://$text';
  return 'https://www.bing.com/search?q=${Uri.encodeQueryComponent(text)}';
}

bool _looksLikeHost(String text) {
  if (text.isEmpty || text.contains(' ')) return false;
  final host = text.split('/').first.split(':').first;
  if (host.isEmpty) return false;
  if (host == 'localhost') return true;
  if (RegExp(r'^\d{1,3}(\.\d{1,3}){3}$').hasMatch(host)) return true;
  return host.contains('.');
}
