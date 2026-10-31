import { showToast } from './showToast';

export function copyToClipboard(text: string) {
  const textarea = document.createElement('textarea');
  textarea.value = text;
  document.body.appendChild(textarea);
  textarea.select();
  try {
    if (!document.execCommand('copy'))
      throw new Error('Clipboard copy rejected');
    showToast(_('Copied'), 'success');
  } catch (_err) {
    showToast(_('Failed to copy!'), 'error');
    console.error('copyToClipboard - e', _err);
  }
  document.body.removeChild(textarea);
}
