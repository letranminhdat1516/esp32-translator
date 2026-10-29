// Port of app/lib/ui/glossary_screen.dart: "Từ điển riêng", terms kept as they are when
// translating. The screen holds no list of its own: after a callback the owner passes new `terms`.
import React, {useState} from 'react';
import {Pressable, ScrollView, StyleSheet, TextInput, View} from 'react-native';
import type {Term} from '../core/model';
import {PrimaryButton, TextButton, Txt} from './components';
import {t} from './copy';
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

  /** A validation message as is; any other failure of a handler (storage, ...) is the generic text. */
  const messageOf = (e: unknown) =>
    e instanceof GlossaryValidationError ? e.message : t('glossary.saveFailed');

  const add = async () => {
    try {
      await onAdd(addText);
    } catch (e) {
      setAddError(messageOf(e));
      return;
    }
    setAddText('');
    setAddError(null);
  };

  const save = async (id: string) => {
    try {
      await onUpdate(id, editText);
    } catch (e) {
      setEditError(messageOf(e));
      return;
    }
    setEditingId(null);
    setEditError(null);
  };

  const remove = async (id: string) => {
    try {
      await onDelete(id);
    } catch (e) {
      setAddError(messageOf(e));
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
        <Pressable accessibilityRole="button" accessibilityLabel={t('glossary.back')} onPress={onBack} style={styles.back}>
          <Txt style={styles.backText}>←</Txt>
        </Pressable>
        <Txt style={styles.barTitle}>{t('glossary.title')}</Txt>
      </View>
      <View style={styles.addRow}>
        <View style={styles.fieldBox}>
          <TextInput
            testID="glossaryField"
            value={addText}
            onChangeText={value => {
              setAddText(value);
              if (addError !== null) {
                setAddError(null);
              }
            }}
            onSubmitEditing={add}
            placeholder={t('glossary.addHint')}
            accessibilityLabel={t('glossary.addHint')}
            placeholderTextColor={Palette.faint}
            style={styles.input}
          />
          {addError !== null ? <Txt style={styles.error} accessibilityLabel={t('glossary.errorLabel', {error: addError})}>
              {addError}
            </Txt> : null}
        </View>
        <PrimaryButton text={t('glossary.add')} onPress={add} style={styles.addButton} />
      </View>
      {terms.length === 0 ? (
        <View style={styles.empty}>
          <Txt style={styles.emptyText}>{t('glossary.empty')}</Txt>
        </View>
      ) : (
        <ScrollView contentContainerStyle={styles.list}>
          {terms.map(term =>
            term.id === editingId ? (
              <View key={term.id} style={styles.editRow}>
                <TextInput
                  testID="glossaryEditField"
                  accessibilityLabel={t('glossary.editLabel')}
                  value={editText}
                  autoFocus
                  onChangeText={value => {
                    setEditText(value);
                    if (editError !== null) {
                      setEditError(null);
                    }
                  }}
                  onSubmitEditing={() => save(term.id)}
                  style={styles.input}
                />
                {editError !== null ? <Txt style={styles.error} accessibilityLabel={t('glossary.errorLabel', {error: editError})}>
                  {editError}
                </Txt> : null}
                <View style={styles.editButtons}>
                  <TextButton
                    text={t('glossary.cancel')}
                    onPress={() => {
                      setEditingId(null);
                      setEditError(null);
                    }}
                  />
                  <TextButton text={t('glossary.save')} onPress={() => save(term.id)} />
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
                      accessibilityLabel={t('glossary.edit', {term: term.text})}
                      onPress={() => startEdit(term)}
                      style={styles.iconButton}>
                      <Txt style={styles.iconText}>✎</Txt>
                    </Pressable>
                    <Pressable
                      accessibilityRole="button"
                      accessibilityLabel={t('glossary.delete', {term: term.text})}
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
