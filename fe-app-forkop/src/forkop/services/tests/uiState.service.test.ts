import { beforeEach, describe, expect, it, vi } from 'vitest';
import { applyUiStateToStore } from '../uiState.service';
import { store } from '../store.service';
import { Forkop } from '../../types';
import {
  clearLocalActionOverlay,
  setLocalComponentAction,
  setLocalLatencyAction,
  setLocalServiceAction,
  setLocalSubscriptionAction,
} from '../localActionOverlay.service';

describe('confirmed restart conflict in UI state', () => {
  it('preserves the immediate guard and resets warnings on a transition', () => {
    const clock = vi.spyOn(Date, 'now');
    try {
      const state = createUiState();
      applyUiStateToStore(state);
      state.service.forkop.status = 'running & enabled';
      state.service.forkop.restart_blocked = 1;
      clock.mockReturnValue(1000);
      applyUiStateToStore(state);
      expect(store.get().servicesInfoWidget.data.restartBlocked).toBe(1);
      expect(store.get().servicesInfoWidget.data.restartConflictConfirmed).toBe(
        false,
      );
      clock.mockReturnValue(6000);
      applyUiStateToStore(state);
      expect(store.get().servicesInfoWidget.data.restartConflictConfirmed).toBe(
        true,
      );
      state.service.forkop.restart_blocked = 0;
      applyUiStateToStore(state);
      expect(store.get().servicesInfoWidget.data.restartConflictConfirmed).toBe(
        false,
      );
      state.service.forkop.restart_blocked = 1;
      applyUiStateToStore(state);
      expect(store.get().servicesInfoWidget.data.restartConflictConfirmed).toBe(
        false,
      );
      state.service.forkop.status = 'restarting';
      applyUiStateToStore(state);
      expect(store.get().servicesInfoWidget.data.restartConflictConfirmed).toBe(
        false,
      );
    } finally {
      clock.mockRestore();
    }
  });
});

describe('per-service memory rows', () => {
  it('passes the services the runtime names through to the widget', () => {
    const state = createUiState();
    state.service.tailscale = { running: 1, memory_rss_bytes: 6602752 };
    state.service.torrserver_direct = { running: 0, memory_rss_bytes: 0 };

    applyUiStateToStore(state);

    expect(store.get().servicesInfoWidget.data.tailscale).toEqual({
      running: 1,
      memoryBytes: 6602752,
    });
    expect(store.get().servicesInfoWidget.data.torrserverDirect).toEqual({
      running: 0,
      memoryBytes: 0,
    });
  });

  it('keeps a service procd does not know out of the widget', () => {
    const state = createUiState();
    state.service.tailscale = null;

    applyUiStateToStore(state);

    expect(store.get().servicesInfoWidget.data.tailscale).toBeNull();
    expect(store.get().servicesInfoWidget.data.torrserverDirect).toBeNull();
  });
});

function createUiState(
  actions: Partial<Forkop.UiState['actions']> = {},
  capabilities: Partial<Forkop.UiState['capabilities']> = {},
): Forkop.UiState {
  return {
    service: {
      forkop: {
        running: 0,
        enabled: 1,
        status: 'starting',
        dns_configured: 0,
      },
      sing_box: {
        running: 0,
        enabled: 1,
        status: 'stopped but enabled',
      },
    },
    capabilities: {
      sing_box_extended: 1,
      sing_box_tiny: 0,
      sing_box_compressed: 0,
      sing_box_tailscale: 1,
      ...capabilities,
    },
    actions: {
      service: [],
      latency: [],
      component: [],
      subscription: [],
      ...actions,
    },
  };
}

describe('applyUiStateToStore', () => {
  it('restores the global subscription update indicator without a section', () => {
    clearLocalActionOverlay();
    applyUiStateToStore(
      createUiState({
        subscription: [
          {
            success: true,
            running: true,
            job_id: 'all-subscriptions',
            section: '',
            message: 'Subscription update is running',
          },
        ],
      }),
    );
    expect(store.get().sectionsWidget.subscriptionUpdatingSections).toEqual({
      '*': true,
    });
    applyUiStateToStore(createUiState());
    expect(store.get().sectionsWidget.subscriptionUpdatingSections).toEqual({});
  });
  it('preserves XHTTP capability independently of the core variant', () => {
    applyUiStateToStore(
      createUiState({}, { sing_box_extended: 0, sing_box_xhttp: 1 }),
    );
    expect(store.get().diagnosticsSystemInfo.sing_box_xhttp).toBe(1);
    expect(store.get().diagnosticsSystemInfo.sing_box_extended).toBe(0);
    applyUiStateToStore(
      createUiState({}, { sing_box_extended: 0, sing_box_xhttp: 0 }),
    );
    expect(store.get().diagnosticsSystemInfo.sing_box_xhttp).toBe(0);
    applyUiStateToStore(createUiState({}, { sing_box_extended: 1 }));
    expect(store.get().diagnosticsSystemInfo.sing_box_xhttp).toBe(1);
  });
  beforeEach(() => {
    clearLocalActionOverlay();
    store.reset();
  });

  it('applies service, capability, and running action state before first render', () => {
    applyUiStateToStore(
      createUiState({
        service: [
          {
            success: true,
            running: true,
            kind: 'service',
            action: 'start',
            job_id: 'service-1',
          },
        ],
        subscription: [
          {
            success: true,
            running: true,
            job_id: 'subscription-1',
            section: 'main',
            message: 'Subscription update is running',
          },
        ],
        latency: [
          {
            success: true,
            running: true,
            kind: 'latency',
            latency_type: 'group',
            section: 'main',
            tag: 'AUTO',
            job_id: 'latency-1',
            progress: {
              completed: 2,
              total: 5,
              failed: 1,
            },
          },
        ],
        component: [
          {
            success: true,
            running: true,
            job_id: 'component-1',
            component: 'sing_box',
            action: 'install',
            message: 'Install is running',
            current_version: '',
            latest_version: '',
            changed: false,
          },
        ],
      }),
    );

    const state = store.get();

    expect(state.servicesInfoWidget).toMatchObject({
      loading: false,
      failed: false,
      data: {
        forkopEnabled: 1,
        forkopRunning: 0,
        forkopStatus: 'starting',
      },
    });
    expect(state.diagnosticsSystemInfo).toMatchObject({
      providerInfoLoaded: true,
      sing_box_extended: 1,
    });
    expect(state.diagnosticsActions.start.loading).toBe(true);
    expect(state.sectionsWidget.subscriptionUpdatingSections).toEqual({
      main: true,
    });
    expect(state.sectionsWidget.latencyFetchingSections).toEqual({
      main: true,
    });
    expect(state.sectionsWidget.latencyProgressSections).toEqual({
      main: {
        completed: 2,
        total: 5,
        failed: 1,
      },
    });
    expect(state.updatesActions.singBoxInstall.loading).toBe(true);
  });

  it('clears finished persisted action flags while preserving local enable actions', () => {
    store.set({
      diagnosticsActions: {
        ...store.get().diagnosticsActions,
        start: { loading: true },
        enable: { loading: true },
      },
      sectionsWidget: {
        ...store.get().sectionsWidget,
        subscriptionUpdatingSections: { main: true },
        latencyFetchingSections: { main: true },
        latencyProgressSections: {
          main: {
            completed: 1,
            total: 2,
            failed: 0,
          },
        },
      },
      updatesActions: {
        ...store.get().updatesActions,
        singBoxInstall: { loading: true },
      },
    });

    applyUiStateToStore(createUiState());

    const state = store.get();

    expect(state.diagnosticsActions.start.loading).toBe(false);
    expect(state.diagnosticsActions.enable.loading).toBe(true);
    expect(state.sectionsWidget.subscriptionUpdatingSections).toEqual({});
    expect(state.sectionsWidget.latencyFetchingSections).toEqual({});
    expect(state.sectionsWidget.latencyProgressSections).toEqual({});
    expect(state.updatesActions.singBoxInstall.loading).toBe(false);
  });

  it('keeps locally started actions loading until their owner clears them', () => {
    setLocalComponentAction('singBoxInstall', true);
    setLocalSubscriptionAction('proxy', true);
    setLocalLatencyAction('gemini', true);
    setLocalServiceAction('restart', true);

    applyUiStateToStore(createUiState());

    expect(store.get().updatesActions.singBoxInstall.loading).toBe(true);
    expect(store.get().sectionsWidget.subscriptionUpdatingSections).toEqual({
      proxy: true,
    });
    expect(store.get().sectionsWidget.latencyFetchingSections).toEqual({
      gemini: true,
    });
    expect(store.get().diagnosticsActions.restart.loading).toBe(true);

    clearLocalActionOverlay();
    applyUiStateToStore(createUiState());

    expect(store.get().updatesActions.singBoxInstall.loading).toBe(false);
    expect(store.get().sectionsWidget.subscriptionUpdatingSections).toEqual({});
    expect(store.get().sectionsWidget.latencyFetchingSections).toEqual({});
    expect(store.get().diagnosticsActions.restart.loading).toBe(false);
  });

  it('preserves local latency progress while waiting for runtime progress', () => {
    setLocalLatencyAction('gemini', true);
    store.set({
      sectionsWidget: {
        ...store.get().sectionsWidget,
        latencyFetchingSections: { gemini: true },
        latencyProgressSections: {
          gemini: {
            completed: 0,
            total: 3,
            failed: 0,
          },
        },
      },
    });

    applyUiStateToStore(createUiState());

    expect(store.get().sectionsWidget.latencyFetchingSections).toEqual({
      gemini: true,
    });
    expect(store.get().sectionsWidget.latencyProgressSections).toEqual({
      gemini: {
        completed: 0,
        total: 3,
        failed: 0,
      },
    });
  });

  it('preserves latency progress for running runtime actions without progress', () => {
    store.set({
      sectionsWidget: {
        ...store.get().sectionsWidget,
        latencyFetchingSections: { main: true },
        latencyProgressSections: {
          main: {
            completed: 2,
            total: 5,
            failed: 0,
          },
        },
      },
    });

    applyUiStateToStore(
      createUiState({
        latency: [
          {
            success: true,
            running: true,
            kind: 'latency',
            latency_type: 'proxy_list',
            section: 'main',
            tag: '["one","two"]',
            job_id: 'latency-1',
          },
        ],
      }),
    );

    expect(store.get().sectionsWidget.latencyFetchingSections).toEqual({
      main: true,
    });
    expect(store.get().sectionsWidget.latencyProgressSections).toEqual({
      main: {
        completed: 2,
        total: 5,
        failed: 0,
      },
    });
  });

  it('maps a running reload action to the restart control', () => {
    applyUiStateToStore(
      createUiState({
        service: [
          {
            success: true,
            running: true,
            kind: 'service',
            action: 'reload',
            job_id: 'service-reload',
          },
        ],
      }),
    );

    expect(store.get().diagnosticsActions.restart.loading).toBe(true);
  });

  it('does not combine a stale extended version with tiny capabilities', () => {
    store.set({
      diagnosticsSystemInfo: {
        ...store.get().diagnosticsSystemInfo,
        sing_box_version: '1.13.12-extended-2.3.2',
        sing_box_extended: 1,
        sing_box_tiny: 0,
      },
    });

    applyUiStateToStore(
      createUiState(undefined, {
        sing_box_extended: 0,
        sing_box_tiny: 1,
        sing_box_compressed: 0,
        sing_box_tailscale: 0,
      }),
    );

    expect(store.get().diagnosticsSystemInfo).toMatchObject({
      sing_box_version: '1.13.12-extended-2.3.2',
      sing_box_extended: 1,
      sing_box_tiny: 0,
      sing_box_tailscale: 1,
    });
  });

  it('keeps current sing-box variant while a different sing-box install action is running', () => {
    store.set({
      diagnosticsSystemInfo: {
        ...store.get().diagnosticsSystemInfo,
        providerInfoLoaded: true,
        sing_box_version: '1.12.25',
        sing_box_extended: 0,
        sing_box_tiny: 1,
        sing_box_compressed: 0,
        sing_box_tailscale: 1,
      },
    });

    applyUiStateToStore(
      createUiState(
        {
          component: [
            {
              success: true,
              running: true,
              job_id: 'sing-box-install',
              component: 'sing_box',
              action: 'install_x',
              message: 'Install is running',
              current_version: '',
              latest_version: '',
              changed: false,
            },
          ],
        },
        {
          sing_box_extended: 0,
          sing_box_tiny: 1,
          sing_box_compressed: 0,
          sing_box_tailscale: 0,
        },
      ),
    );

    expect(store.get().diagnosticsSystemInfo).toMatchObject({
      providerInfoLoaded: true,
      sing_box_version: '1.12.25',
      sing_box_extended: 0,
      sing_box_tiny: 1,
      sing_box_compressed: 0,
      sing_box_tailscale: 0,
    });
    expect(store.get().updatesActions.singBoxInstallX.loading).toBe(true);
  });

  it('marks the running sing-box install action without pretending it is installed', () => {
    applyUiStateToStore(
      createUiState(
        {
          component: [
            {
              success: true,
              running: true,
              job_id: 'sing-box-install',
              component: 'sing_box',
              action: 'install_rust_x',
              message: 'Install is running',
              current_version: '',
              latest_version: '',
              changed: false,
            },
          ],
        },
        {
          sing_box_extended: 0,
          sing_box_tiny: 1,
          sing_box_compressed: 0,
          sing_box_tailscale: 0,
        },
      ),
    );

    expect(store.get().diagnosticsSystemInfo).toMatchObject({
      sing_box_extended: 0,
      sing_box_tiny: 1,
      sing_box_compressed: 0,
      sing_box_tailscale: 0,
    });
    expect(store.get().updatesActions.singBoxInstallRustX.loading).toBe(true);
  });
});
