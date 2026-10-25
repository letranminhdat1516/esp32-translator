import 'dart:async';

import 'package:flutter/material.dart';

import '../core/model.dart';
import 'theme.dart';

/// Thrown by the glossary callbacks when a term is rejected; [message] is
/// shown under the field. The controller maps the store's rejections to the
/// texts in [GlossaryMessages].
class GlossaryValidationError implements Exception {
  const GlossaryValidationError(this.message);
  final String message;

  @override
  String toString() => 'GlossaryValidationError($message)';
}

/// The Vietnamese validation messages.
abstract final class GlossaryMessages {
  static const empty = 'Từ không được để trống';
  static const tooLong = 'Tối đa 64 ký tự';
  static const tooMany = 'Tối đa 500 từ';
  static const badCharacters = 'Có ký tự không hợp lệ';
}

/// "Từ điển riêng": terms that are kept as they are when translating. The
/// screen holds no list of its own: after a callback the owner passes the new
/// [terms].
class GlossaryScreen extends StatefulWidget {
  const GlossaryScreen({
    super.key,
    required this.terms,
    required this.onAdd,
    required this.onUpdate,
    required this.onDelete,
  });

  final List<Term> terms;

  /// May throw [GlossaryValidationError].
  final FutureOr<void> Function(String text) onAdd;

  /// May throw [GlossaryValidationError].
  final FutureOr<void> Function(String id, String text) onUpdate;
  final FutureOr<void> Function(String id) onDelete;

  @override
  State<GlossaryScreen> createState() => _GlossaryScreenState();
}

class _GlossaryScreenState extends State<GlossaryScreen> {
  final _addController = TextEditingController();
  final _editController = TextEditingController();
  String? _addError;
  String? _editError;
  String? _editingId;

  @override
  void dispose() {
    _addController.dispose();
    _editController.dispose();
    super.dispose();
  }

  Future<void> _add() async {
    try {
      await widget.onAdd(_addController.text);
    } on GlossaryValidationError catch (e) {
      if (mounted) setState(() => _addError = e.message);
      return;
    }
    if (!mounted) return;
    _addController.clear();
    setState(() => _addError = null);
  }

  Future<void> _save(String id) async {
    try {
      await widget.onUpdate(id, _editController.text);
    } on GlossaryValidationError catch (e) {
      if (mounted) setState(() => _editError = e.message);
      return;
    }
    if (!mounted) return;
    setState(() {
      _editingId = null;
      _editError = null;
    });
  }

  Future<void> _delete(String id) async {
    try {
      await widget.onDelete(id);
    } on GlossaryValidationError catch (e) {
      if (mounted) setState(() => _addError = e.message);
    }
  }

  void _startEdit(Term term) {
    setState(() {
      _editingId = term.id;
      _editError = null;
      _editController.text = term.text;
    });
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      backgroundColor: Palette.ground,
      appBar: AppBar(
        backgroundColor: Palette.ground,
        surfaceTintColor: Colors.transparent,
        title: const Text(
          'Từ điển riêng',
          style: TextStyle(fontSize: 18, fontWeight: FontWeight.w600),
        ),
      ),
      body: SafeArea(
        child: Column(
          children: [
            Padding(
              padding: const EdgeInsets.fromLTRB(20, 8, 20, 4),
              child: Row(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Expanded(
                    child: TextField(
                      key: const Key('glossaryField'),
                      controller: _addController,
                      onChanged: (_) {
                        if (_addError != null) setState(() => _addError = null);
                      },
                      onSubmitted: (_) => _add(),
                      decoration: _decoration(
                        'Thêm từ giữ nguyên',
                        _addError,
                      ),
                    ),
                  ),
                  const SizedBox(width: 12),
                  Padding(
                    padding: const EdgeInsets.only(top: 4),
                    child: FilledButton(
                      onPressed: _add,
                      style: FilledButton.styleFrom(
                        backgroundColor: Palette.accent,
                        foregroundColor: Colors.white,
                        shape: const StadiumBorder(),
                        minimumSize: const Size(0, 48),
                        padding: const EdgeInsets.symmetric(horizontal: 22),
                      ),
                      child: const Text('Thêm'),
                    ),
                  ),
                ],
              ),
            ),
            Expanded(
              child: widget.terms.isEmpty
                  ? const Center(
                      child: Text(
                        'Chưa có từ nào',
                        style: TextStyle(color: Palette.muted, fontSize: 15),
                      ),
                    )
                  : ListView(
                      padding: const EdgeInsets.symmetric(vertical: 8),
                      children: [for (final t in widget.terms) _row(t)],
                    ),
            ),
          ],
        ),
      ),
    );
  }

  InputDecoration _decoration(String hint, String? error) => InputDecoration(
    hintText: hint,
    hintStyle: const TextStyle(color: Palette.faint),
    errorText: error,
    errorStyle: const TextStyle(color: Color(0xFFE5645A)),
    filled: true,
    fillColor: Palette.surface,
    contentPadding: const EdgeInsets.symmetric(horizontal: 16, vertical: 14),
    border: OutlineInputBorder(
      borderRadius: BorderRadius.circular(24),
      borderSide: BorderSide.none,
    ),
  );

  Widget _row(Term term) {
    if (term.id == _editingId) return _editRow(term);
    final editable = term.origin == TermOrigin.user;
    return ListTile(
      key: ValueKey('term-${term.id}'),
      contentPadding: const EdgeInsets.symmetric(horizontal: 20),
      title: Text(
        term.text,
        style: const TextStyle(fontSize: 17, fontWeight: FontWeight.w600),
      ),
      subtitle: term.variants.isEmpty
          ? null
          : Text(
              term.variants.join(', '),
              style: const TextStyle(fontSize: 14, color: Palette.muted),
            ),
      trailing: editable
          ? Row(
              mainAxisSize: MainAxisSize.min,
              children: [
                IconButton(
                  tooltip: 'Sửa ${term.text}',
                  icon: const Icon(Icons.edit_outlined, color: Palette.muted),
                  onPressed: () => _startEdit(term),
                ),
                IconButton(
                  tooltip: 'Xoá ${term.text}',
                  icon: const Icon(Icons.delete_outline, color: Palette.muted),
                  onPressed: () => _delete(term.id),
                ),
              ],
            )
          : null,
    );
  }

  Widget _editRow(Term term) => Padding(
    key: ValueKey('term-${term.id}'),
    padding: const EdgeInsets.symmetric(horizontal: 20, vertical: 6),
    child: Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        TextField(
          key: const Key('glossaryEditField'),
          controller: _editController,
          autofocus: true,
          onChanged: (_) {
            if (_editError != null) setState(() => _editError = null);
          },
          onSubmitted: (_) => _save(term.id),
          decoration: _decoration('', _editError),
        ),
        Row(
          mainAxisAlignment: MainAxisAlignment.end,
          children: [
            TextButton(
              onPressed: () => setState(() {
                _editingId = null;
                _editError = null;
              }),
              child: const Text('Huỷ'),
            ),
            TextButton(
              onPressed: () => _save(term.id),
              child: const Text('Lưu'),
            ),
          ],
        ),
      ],
    ),
  );
}
