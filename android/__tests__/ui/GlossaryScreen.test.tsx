import React, {useState} from 'react';
import {fireEvent, render, screen} from '@testing-library/react-native';
import fixture from '../../../shared/fixtures/glossary.json';
import {GlossaryScreen} from '../../src/ui/GlossaryScreen';
import type {Term} from '../../src/core/model';
import {GlossaryMessages, GlossaryValidationError, glossaryMessageFor} from '../../src/ui/uiState';

const term = (id: string, text: string, origin: Term['origin'] = 'user', variants: string[] = []): Term => ({
  id,
  text,
  variants,
  fixed: {},
  origin,
});
const alpha = term('a', 'Zorvik');
const beta = term('b', 'Cicca', 'user', ['Chika']);
const builtIn = term('c', 'iPhone', 'builtIn');

/** Owns the list like the controller will. */
function Host({initial = [], reject}: {initial?: Term[]; reject?: string}) {
  const [terms, setTerms] = useState<Term[]>(initial);
  const [n, setN] = useState(0);
  const check = () => {
    if (reject) {
      throw new GlossaryValidationError(reject);
    }
  };
  return (
    <GlossaryScreen
      terms={terms}
      onBack={() => {}}
      onAdd={text => {
        check();
        setTerms([...terms, term(`n${n}`, text)]);
        setN(n + 1);
      }}
      onUpdate={(id, text) => {
        check();
        setTerms(terms.map(x => (x.id === id ? term(id, text) : x)));
      }}
      onDelete={id => setTerms(terms.filter(x => x.id !== id))}
    />
  );
}

describe('GlossaryScreen', () => {
  it('shows the title and the terms, empty hint without terms', async () => {
    const a = await render(<Host />);
    expect(screen.getByText('Từ điển riêng')).toBeTruthy();
    expect(screen.getByText('Chưa có từ nào')).toBeTruthy();
    await a.unmount();
    await render(<Host initial={[alpha, beta]} />);
    expect(screen.getByText('Zorvik')).toBeTruthy();
    expect(screen.getByText('Cicca')).toBeTruthy();
    expect(screen.getByText('Chika')).toBeTruthy();
    expect(screen.queryByText('Chưa có từ nào')).toBeNull();
  });

  it('add: the term lands in the list and the field clears', async () => {
    await render(<Host />);
    await fireEvent.changeText(screen.getByTestId('glossaryField'), 'Zorvik');
    await fireEvent.press(screen.getByText('Thêm'));
    expect(await screen.findByText('Zorvik')).toBeTruthy();
    expect(screen.getByTestId('glossaryField').props.value).toBe('');
  });

  for (const message of Object.values(GlossaryMessages)) {
    it(`add rejected: "${message}" shown under the field, typing clears it`, async () => {
      await render(<Host reject={message} />);
      await fireEvent.changeText(screen.getByTestId('glossaryField'), 'x');
      await fireEvent.press(screen.getByText('Thêm'));
      expect(await screen.findByText(message)).toBeTruthy();
      expect(screen.getByTestId('glossaryField').props.value).toBe('x');
      await fireEvent.changeText(screen.getByTestId('glossaryField'), 'xy');
      expect(screen.queryByText(message)).toBeNull();
    });
  }

  it('the messages match the store errors of shared/fixtures/glossary.json', async () => {
    const names = new Set<string>();
    for (const c of fixture.cases as Array<{expect: {error?: string}}>) {
      if (c.expect.error) {
        names.add(c.expect.error);
      }
    }
    expect([...names].sort()).toEqual(
      ['DuplicateTerm', 'EmptyText', 'ForbiddenCharacter', 'TooLong', 'TooManyTerms', 'TooManyVariants', 'UnknownTerm'].sort(),
    );
    expect(fixture.limits).toEqual({maxTerms: 500, maxLength: 64, maxVariants: 8});
    expect(glossaryMessageFor('EmptyText')).toBe('Từ không được để trống');
    expect(glossaryMessageFor('TooLong')).toBe('Tối đa 64 ký tự');
    expect(glossaryMessageFor('TooManyTerms')).toBe('Tối đa 500 từ');
    expect(glossaryMessageFor('ForbiddenCharacter')).toBe('Có ký tự không hợp lệ');
    expect(glossaryMessageFor('UnknownTerm')).toBeUndefined();
  });

  it('delete removes the term', async () => {
    await render(<Host initial={[alpha, beta]} />);
    await fireEvent.press(screen.getByLabelText('Xoá Zorvik'));
    expect(await screen.findByText('Cicca')).toBeTruthy();
    expect(screen.queryByText('Zorvik')).toBeNull();
  });

  it('edit: Lưu updates, Huỷ leaves it', async () => {
    await render(<Host initial={[alpha]} />);
    await fireEvent.press(screen.getByLabelText('Sửa Zorvik'));
    await fireEvent.changeText(screen.getByTestId('glossaryEditField'), 'Zorvik2');
    await fireEvent.press(screen.getByText('Lưu'));
    expect(await screen.findByText('Zorvik2')).toBeTruthy();
    expect(screen.queryByTestId('glossaryEditField')).toBeNull();

    await fireEvent.press(screen.getByLabelText('Sửa Zorvik2'));
    await fireEvent.press(screen.getByText('Huỷ'));
    expect(screen.getByText('Zorvik2')).toBeTruthy();
    expect(screen.queryByTestId('glossaryEditField')).toBeNull();
  });

  it('edit rejected: message under the edit field, stays open', async () => {
    await render(<Host initial={[alpha]} reject="Tối đa 64 ký tự" />);
    await fireEvent.press(screen.getByLabelText('Sửa Zorvik'));
    await fireEvent.changeText(screen.getByTestId('glossaryEditField'), 'y');
    await fireEvent.press(screen.getByText('Lưu'));
    expect(await screen.findByText('Tối đa 64 ký tự')).toBeTruthy();
    expect(screen.getByTestId('glossaryEditField')).toBeTruthy();
  });

  it('built-in terms cannot be edited or deleted', async () => {
    await render(<Host initial={[builtIn]} />);
    expect(screen.getByText('iPhone')).toBeTruthy();
    expect(screen.queryByLabelText('Sửa iPhone')).toBeNull();
    expect(screen.queryByLabelText('Xoá iPhone')).toBeNull();
  });

  it('snapshot: glossary', async () => {
    const r = await render(<Host initial={[alpha, beta, builtIn]} />);
    expect(r.toJSON()).toMatchSnapshot();
  });
});
