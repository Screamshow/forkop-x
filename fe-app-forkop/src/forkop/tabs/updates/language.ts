import { renderButton } from '../../../partials';
import {
  getForkopLanguage,
  setForkopLanguage,
} from '../../../helpers/forkopLanguage';

let saving = false;

export function renderLanguage(disabled: boolean) {
  const status = E('p', { role: 'status' });
  const buttons = (['ru', 'en'] as const).map((language) =>
    renderButton({
      text: language === 'ru' ? 'Русский' : 'English',
      disabled: disabled || saving || getForkopLanguage() === language,
      onClick: () => {
        if (saving) return;
        saving = true;
        buttons.forEach((button) => (button.disabled = true));
        void (async () => {
          try {
            setForkopLanguage(language);
            window.location.reload();
          } catch {
            saving = false;
            buttons.forEach((button) => (button.disabled = disabled));
            status.textContent = _(
              'Could not change language. Please try again.',
            );
          }
        })();
      },
    }),
  );
  return E('div', { class: 'fkp_updates-page__component' }, [
    E('div', { class: 'fkp_updates-page__component__header' }, [
      E(
        'span',
        { class: 'fkp_updates-page__component__title' },
        _('Interface language'),
      ),
    ]),
    E('p', {}, _('Change Forkop X interface language')),
    E(
      'div',
      { class: 'fkp_updates-page__component__language-buttons' },
      buttons,
    ),
    status,
  ]);
}
