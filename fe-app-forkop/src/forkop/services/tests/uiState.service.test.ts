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
      xrust: {
        running: 0,
        enabled: 1,
        status: 'stopped but enabled',
      },
    },
    capabilities: {
      xrust_tailscale: 1,
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
  it('keeps the dashboard data out of unchanged action polls', () => {
    const state = createUiState();
    state.actions.subscription = [
      { section: 'main', running: true, success: true },
    ];
    applyUiStateToStore(state);
    const set = vi.spyOn(store, 'set');
    try {
      applyUiStateToStore(state);
      expect(
        set.mock.calls.some(([update]) => 'sectionsWidget' in update),
      ).toBe(false);

      state.actions.subscription = [];
      applyUiStateToStore(state);
      expect(store.get().sectionsWidget.subscriptionUpdatingSections).toEqual(
        {},
      );
    } finally {
      set.mockRestore();
    }
  });

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
  it('applies Xrust Tailscale capability without replacing the installed version', () => {
    store.set({
      diagnosticsSystemInfo: {
        ...store.get().diagnosticsSystemInfo,
        xrust_version: '0.0.44',
      },
    });
    applyUiStateToStore(createUiState({}, { xrust_tailscale: 1 }));
    expect(store.get().diagnosticsSystemInfo.xrust_tailscale).toBe(1);
    applyUiStateToStore(createUiState({}, { xrust_tailscale: 0 }));
    expect(store.get().diagnosticsSystemInfo).toMatchObject({
      xrust_version: '0.0.44',
      xrust_tailscale: 0,
    });
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
            component: 'forkop',
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
      xrust_tailscale: 1,
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
    expect(state.updatesActions.forkopInstall.loading).toBe(true);
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
        forkopInstall: { loading: true },
      },
    });

    applyUiStateToStore(createUiState());

    const state = store.get();

    expect(state.diagnosticsActions.start.loading).toBe(false);
    expect(state.diagnosticsActions.enable.loading).toBe(true);
    expect(state.sectionsWidget.subscriptionUpdatingSections).toEqual({});
    expect(state.sectionsWidget.latencyFetchingSections).toEqual({});
    expect(state.sectionsWidget.latencyProgressSections).toEqual({});
    expect(state.updatesActions.forkopInstall.loading).toBe(false);
  });

  it('keeps locally started actions loading until their owner clears them', () => {
    setLocalComponentAction('forkopInstall', true);
    setLocalSubscriptionAction('proxy', true);
    setLocalLatencyAction('gemini', true);
    setLocalServiceAction('restart', true);

    applyUiStateToStore(createUiState());

    expect(store.get().updatesActions.forkopInstall.loading).toBe(true);
    expect(store.get().sectionsWidget.subscriptionUpdatingSections).toEqual({
      proxy: true,
    });
    expect(store.get().sectionsWidget.latencyFetchingSections).toEqual({
      gemini: true,
    });
    expect(store.get().diagnosticsActions.restart.loading).toBe(true);

    clearLocalActionOverlay();
    applyUiStateToStore(createUiState());

    expect(store.get().updatesActions.forkopInstall.loading).toBe(false);
    expect(store.get().sectionsWidget.subscriptionUpdatingSections).toEqual({});
    expect(store.get().sectionsWidget.latencyFetchingSections).toEqual({});
    expect(store.get().diagnosticsActions.restart.loading).toBe(false);
  });

  it('shows automatic sweep progress on every dashboard section and clears it', () => {
    const data = [
      { sectionName: 'main' },
      { sectionName: 'new-subscription' },
    ] as unknown as ReturnType<typeof store.get>['sectionsWidget']['data'];
    store.set({ sectionsWidget: { ...store.get().sectionsWidget, data } });
    applyUiStateToStore(
      createUiState({
        latency: [
          {
            success: true,
            running: true,
            kind: 'latency',
            latency_type: 'proxy_list',
            section: '*',
            tag: '[]',
            job_id: 'automatic-1',
            progress: { completed: 4, total: 12, failed: 1 },
          },
        ],
      }),
    );
    expect(store.get().sectionsWidget.latencyFetchingSections).toEqual({
      main: true,
      'new-subscription': true,
    });
    expect(store.get().sectionsWidget.latencyProgressSections.main).toEqual({
      completed: 4,
      total: 12,
      failed: 1,
    });
    applyUiStateToStore(createUiState());
    expect(store.get().sectionsWidget.latencyProgressSections).toEqual({});
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
});
