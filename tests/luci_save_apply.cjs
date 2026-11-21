const assert = require('node:assert/strict');
const fs = require('node:fs');
const vm = require('node:vm');

const source = fs.readFileSync('luci-app-forkop/htdocs/luci-static/resources/view/forkop/forkop.js', 'utf8');
// LuCI exports a class constructor; handlers belong to its prototype.
const nativeSource = process.argv[2] && fs.readFileSync(process.argv[2], 'utf8');
const nativeHandler = nativeSource && nativeSource.match(/handleSaveApply\(ev,mode\)\{return this\.handleSave\(ev\)\.then\(\(\)=>\{classes\.ui\.changes\.apply\(mode=='0'\);\}\);\}/)?.[0];
if (nativeSource) assert.ok(nativeHandler, 'find the VM native LuCI handler');

(async () => {
  for (const mode of ['0', '1']) {
    for (const failure of [false, true]) {
      const events = [];
      const scheduled = [];
      const error = Error('form validation failed');
      let entry;
      const changes = { apply(checked) { events.push(['apply', checked]); } };
      function View() {}
      View.prototype.handleSaveApply = nativeHandler
        ? vm.runInNewContext(`({${nativeHandler}}).handleSaveApply`, { classes: { ui: { changes } } })
        : function (ev, selectedMode) {
          return this.handleSave(ev).then(() => changes.apply(selectedMode === '0'));
        };
      View.extend = properties => Object.assign(Object.create(View.prototype), properties);
      entry = vm.runInNewContext(`(function () { ${source} })()`, {
        view: View,
        main: { ForkopShellMethods: { getUiState: async () => {
          events.push(['refresh']); return { success: true, data: {} };
        } }, applyUiStateToStore() {} },
        window: { setTimeout(fn, delay) { scheduled.push([fn, delay]); } },
      });
      entry.handleSave = function (ev) {
        assert.equal(this, entry);
        assert.equal(ev, 'click');
        events.push(['save']);
        return failure ? Promise.reject(error) : Promise.resolve();
      };
      if (failure) {
        await assert.rejects(entry.handleSaveApply('click', mode), e => e === error);
        assert.deepEqual(events, [['save'], ['refresh']]);
        assert.equal(scheduled.length, 0);
      } else {
        await entry.handleSaveApply('click', mode);
        assert.deepEqual(events, [['save'], ['apply', mode === '0']]);
        assert.equal(scheduled[0][1], 250);
        await scheduled[0][0]();
        assert.deepEqual(events.at(-1), ['refresh']);
      }
    }
  }
  const events = [];
  const listeners = {};
  let pending;
  function displayStatus(status, content) { events.push([status, content]); }
  const changes = {
    apply() {},
    displayStatus,
    confirm(success) {
      this.displayStatus('notice spinning', 'applying');
      if (!success) {
        this.displayStatus('warning', 'native rollback');
        return;
      }
      listeners['uci-applied']();
      this.displayStatus('notice', 'native UCI confirmation');
    },
  };
  const context = {
    document: { addEventListener(name, callback) { listeners[name] = callback; } },
    view: { extend() {} },
    ui: { changes },
    uci: { changes: () => Promise.resolve(pending) },
    L: { env: { apply_holdoff: 4 } },
    main: { FORKOP_UCI_PACKAGE: 'forkop', translateForkop: text => text },
  };
  vm.runInNewContext(
    `(function () { ${source.replace('return view.extend(EntryPoint);', 'configureForkopApplyHoldoff();')} })()`,
    context,
  );
  for (const [packages, success, finalStatus] of [
    [{ forkop: [['set']] }, true, [null, undefined]],
    [{ forkop: [['set']], network: [['set']] }, true, [null, undefined]],
    [{ forkop: [['set']] }, false, ['warning', 'native rollback']],
    [{ network: [['set']] }, true, ['notice', 'native UCI confirmation']],
  ]) {
    pending = packages;
    await changes.apply();
    changes.confirm(success);
    assert.deepEqual(events.splice(0), [['notice spinning', 'applying'], finalStatus]);
    assert.equal(changes.displayStatus, displayStatus);
    assert.equal(context.L.env.apply_holdoff, 4);
  }
  console.log('PASS: native prototype dispatch, save before apply, checked/unchecked modes and validation failure');
  console.log('PASS: Forkop success modal dismissed, progress and rollback unchanged');
})().catch(error => { console.error(error); process.exitCode = 1; });
