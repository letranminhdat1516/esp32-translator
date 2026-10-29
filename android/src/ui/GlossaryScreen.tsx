// Port of app/lib/ui/glossary_screen.dart: "Từ điển riêng", terms kept as they are when
// translating. The screen holds no list of its own: after a callback the owner passes new `terms`.
import React, {useState} from 'react';
import {Pressable, ScrollView, StyleSheet, TextInput, View} from 'react-native';
import type {Term} from '../core/model';
import {PrimaryButton, TextButton, Txt} from './components';
import {Palette, Spacing, Type, fontFamily} from './theme';
import {GlossaryValidationError} from './uiState';

export interface GlossaryScreenProps {
  terms: readonly Term[];
  /** May throw (or reject with) `GlossaryValidationError`. */
  onAdd: (text: string) => void | Promise<void>;
  /** May throw (or reject with) `GlossaryValidationError`. */
  onUpdate: (id: string, text: string) => void | Promise<void>;
  onDelete: (id: string) => void | Promise<void>;
  onBack: () => void;
}

export function GlossaryScreen({terms, onAdd, onUpdate, onDelete, onBack}: GlossaryScreenProps) {
  const [addText, setAddText] = useState('');
  const [editText, setEditText] = useState('');
  const [addError, setAddError] = useState<string | null>(null);
  const [editError, setEditError] = useState<string | null>(null);
  const [editingId, setEditingId] = useState<string | null>(null);

  const add = async () => {
    try {
      await onAdd(addText);
    } catch (e) {
      if (e instanceof GlossaryValidationError) {
        setAddError(e.message);
        return;
      }
      throw e;
    }
    setAddText('');
    setAddError(null);
  };

  const save = async (id: string) => {
    try {
      await onUpdate(id, editText);
    } catch (e) {
      if (e instanceof GlossaryValidationError) {
        setEditError(e.message);
        return;
      }
      throw e;
    }
    setEditingId(null);
    setEditError(null);
  };

  const remove = async (id: string) => {
    try {
      await onDelete(id);
    } catch (e) {
      if (e instanceof GlossaryValidationError) {
        setAddError(e.message);
        return;
      }
      throw e;
    }
  };

  const startEdit = (term: Term) => {
    setEditingId(term.id);
    setEditError(null);
    setEditText(term.text);
  };

  return (
    <View style={styles.screen}>
      <View style={styles.bar}>
        <Pressable accessibilityRole="button" accessibilityLabel="Quay lại" onPress={onBack} style={styles.back}>
          <Txt style={styles.backText}>←</Txt>
        </Pressable>
        <Txt style={styles.barTitle}>Từ điển riêng</Txt>
      </View>
      <View style={styles.addRow}>
        <View style={styles.fieldBox}>
          <TextInput
            testID="glossaryField"
            value={addText}
            onChangeText={t => {
              setAddText(t);
              if (addError !== null) {
                setAddError(null);
              }
            }}
            onSubmitEditing={add}
            placeholder="Thêm từ giữ nguyên"
            placeholderTextColor={Palette.faint}
            style={styles.input}
          />
          {addError !== null ? <Txt style={styles.error}>{addError}</Txt> : null}
        </View>
        <PrimaryButton text="Thêm" onPress={add} style={styles.addButton} />
      </View>
      {terms.length === 0 ? (
        <View style={styles.empty}>
          <Txt style={styles.emptyText}>Chưa có từ nào</Txt>
        </View>
      ) : (
        <ScrollView contentContainerStyle={styles.list}>
          {terms.map(term =>
            term.id === editingId ? (
              <View key={term.id} style={styles.editRow}>
                <TextInput
                  testID="glossaryEditField"
                  value={editText}
                  autoFocus
                  onChangeText={t => {
                    setEditText(t);
                    if (editError !== null) {
                      setEditError(null);
                    }
                  }}
                  onSubmitEditing={() => save(term.id)}
                  style={styles.input}
                />
                {editError !== null ? <Txt style={styles.error}>{editError}</Txt> : null}
                <View style={styles.editButtons}>
                  <TextButton
                    text="Huỷ"
                    onPress={() => {
                      setEditingId(null);
                      setEditError(null);
                    }}
                  />
                  <TextButton text="Lưu" onPress={() => save(term.id)} />
                </View>
              </View>
            ) : (
              <View key={term.id} style={styles.termRow}>
                <View style={styles.termText}>
                  <Txt style={styles.termTitle}>{term.text}</Txt>
                  {term.variants.length > 0 ? (
                    <Txt style={styles.termSub}>{term.variants.join(', ')}</Txt>
                  ) : null}
                </View>
                {term.origin === 'user' ? (
                  <View style={styles.termActions}>
                    <Pressable
                      accessibilityRole="button"
                      accessibilityLabel={`Sửa ${term.text}`}
                      onPress={() => startEdit(term)}
                      style={styles.iconButton}>
                      <Txt style={styles.iconText}>✎</Txt>
                    </Pressable>
                    <Pressable
                      accessibilityRole="button"
                      accessibilityLabel={`Xoá ${term.text}`}
                      onPress={() => remove(term.id)}
                      style={styles.iconButton}>
                      <Txt style={styles.iconText}>🗑</Txt>
                    </Pressable>
                  </View>
                ) : null}
              </View>
            ),
          )}
        </ScrollView>
      )}
    </View>
  );
}

const styles = StyleSheet.create({
  screen: {flex: 1, backgroundColor: Palette.ground},
  bar: {flexDirection: 'row', alignItems: 'center', paddingHorizontal: Spacing.s, height: 56},
  back: {width: 44, height: 44, alignItems: 'center', justifyContent: 'center'},
  backText: {fontSize: 22, color: Palette.text},
  barTitle: {fontSize: Type.title, marginLeft: Spacing.s},
  addRow: {
    flexDirection: 'row',
    alignItems: 'flex-start',
    gap: Spacing.m,
    paddingHorizontal: Spacing.xl,
    paddingTop: Spacing.s,
    paddingBottom: Spacing.xs,
  },
  fieldBox: {flex: 1},
  input: {
    backgroundColor: Palette.surface,
    borderRadius: 24,
    paddingHorizontal: Spacing.l,
    paddingVertical: 14,
    color: Palette.text,
    fontFamily,
    fontSize: Type.body,
  },
  error: {color: Palette.error, fontSize: Type.caption, marginTop: Spacing.xs, marginLeft: Spacing.l},
  addButton: {paddingHorizontal: 22, paddingVertical: 14, marginTop: 4},
  empty: {flex: 1, alignItems: 'center', justifyContent: 'center'},
  emptyText: {color: Palette.muted, fontSize: Type.body},
  list: {paddingVertical: Spacing.s},
  termRow: {
    flexDirection: 'row',
    alignItems: 'center',
    paddingHorizontal: Spacing.xl,
    paddingVertical: Spacing.s,
  },
  termText: {flex: 1},
  termTitle: {fontSize: Type.row},
  termSub: {fontSize: Type.secondary, color: Palette.muted},
  termActions: {flexDirection: 'row'},
  iconButton: {width: 44, height: 44, alignItems: 'center', justifyContent: 'center'},
  iconText: {fontSize: 18, color: Palette.muted},
  editRow: {paddingHorizontal: Spacing.xl, paddingVertical: 6},
  editButtons: {flexDirection: 'row', justifyContent: 'flex-end'},
});
