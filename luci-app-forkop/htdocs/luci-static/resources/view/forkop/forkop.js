"use strict";
"require view";
"require form";
"require baseclass";
"require uci";
"require ui";
"require view.forkop.main as main";
"require view.forkop.tailscale as tailscale";

// Global settings
"require view.forkop.settings as settings";
"require view.forkop.whatsapp as whatsapp";

// Sections
"require view.forkop.section as section";

// Dashboard
"require view.forkop.dashboard as dashboard";

// Monitoring
"require view.forkop.monitoring as monitoring";

// Diagnostic
"require view.forkop.diagnostic as diagnostic";

// Updates
"require view.forkop.updates as updates";
const _ = main.translateForkop;

// Keep LuCI's apply/confirm/rollback protocol, but skip its network settling
// delay when the complete set of staged changes belongs to Forkop alone.
function configureForkopApplyHoldoff() {
  const changes = ui.changes;
  if (changes.forkopHoldoffConfigured) return;
  changes.forkopHoldoffConfigured = true;

  const originalApply = changes.apply;
  const originalConfirm = changes.confirm;
  let forkopOnly = false;

  changes.apply = function () {
    const context = this;
    const args = arguments;
    forkopOnly = false;
    return uci
      .changes()
      .catch(() => null)
      .then((pending) => {
        const packages = Object.keys(pending || {});
        forkopOnly =
          packages.every((name) => Array.isArray(pending[name])) &&
          packages.filter((name) => pending[name].length > 0).length === 1 &&
          Array.isArray(pending?.[main.FORKOP_UCI_PACKAGE]) &&
          pending[main.FORKOP_UCI_PACKAGE].length > 0;
        return originalApply.apply(context, args);
      });
  };

  changes.confirm = function () {
    const skipHoldoff = forkopOnly;
    forkopOnly = false;
    const holdoff = L.env.apply_holdoff;
    try {
      // Native confirm schedules its first request synchronously. Restore the
      // shared setting immediately, including when native confirm throws.
      if (skipHoldoff) L.env.apply_holdoff = 0;
      return originalConfirm.apply(this, arguments);
    } finally {
      L.env.apply_holdoff = holdoff;
    }
  };
}

const UCI_PACKAGE = main.FORKOP_UCI_PACKAGE;

function renderSectionAdd(sectionRef, extra_class) {
  const el = form.GridSection.prototype.renderSectionAdd.apply(sectionRef, [
    extra_class,
  ]);
  const nameEl = el.querySelector(".cbi-section-create-name");

  ui.addValidator(
    nameEl,
    "uciname",
    true,
    (value) => {
      const button = el.querySelector(".cbi-section-create > .cbi-button-add");
      const uciconfig = sectionRef.uciconfig || sectionRef.map.config;

      if (!value) {
        button.disabled = true;
        return true;
      }

      if (uci.get(uciconfig, value)) {
        button.disabled = true;
        return _("Expecting: %s").format(_("unique UCI identifier"));
      }

      button.disabled = null;
      return true;
    },
    "blur",
    "keyup",
  );

  return el;
}

function getRuleEditButtonText() {
  const label = _("Edit rule action");

  return label === "Edit rule action" ? "Edit" : label;
}

function configureGridSection(sectionRef, type, title, addTitle) {
  sectionRef.anonymous = false;
  sectionRef.addremove = true;
  sectionRef.sortable = true;
  sectionRef.rowcolors = true;
  sectionRef.nodescriptions = true;
  sectionRef.modaltitle = function (section_id) {
    const label = uci.get(UCI_PACKAGE, section_id, "label");
    return section_id ? `${title}: ${label || section_id}` : addTitle;
  };
  sectionRef.sectiontitle = function (section_id) {
    return uci.get(UCI_PACKAGE, section_id, "label") || section_id;
  };
  sectionRef.renderSectionAdd = function (extra_class) {
    return renderSectionAdd(sectionRef, extra_class);
  };

  if (type === "section") {
    sectionRef.renderRowActions = function (section_id) {
      return form.TableSection.prototype.renderRowActions.call(
        this,
        section_id,
        getRuleEditButtonText(),
      );
    };
  }
}

const EntryPoint = {
  // LuCI dispatches Save & Apply to the view, not the form.Map.
  handleSaveApply(ev, mode) {
    const refreshUiState = function () {
      main.ForkopShellMethods.getUiState()
        .then((response) => {
          if (
            response?.success &&
            typeof main.applyUiStateToStore === "function"
          ) {
            main.applyUiStateToStore(response.data);
          }
        })
        .catch(() => null);
    };

    if (main.store && typeof main.store.set === "function") {
      const servicesInfoWidget = main.store.get().servicesInfoWidget;
      main.store.set({
        servicesInfoWidget: {
          ...servicesInfoWidget,
          data: {
            ...servicesInfoWidget.data,
            forkopStatus: "reloading",
          },
        },
      });
    }

    return Promise.resolve()
      .then(() => view.prototype.handleSaveApply.call(this, ev, mode))
      .then((result) => {
        window.setTimeout(refreshUiState, 250);

        return result;
      })
      .catch((error) => {
        refreshUiState();

        throw error;
      });
  },

  async render() {
    configureForkopApplyHoldoff();
    main.injectGlobalStyles();
    const uiCapabilities = {
      loaded: false,
      singBoxExtended: false,
      singBoxTiny: false,
      singBoxTailscale: true,
    };
    let uiCapabilitiesPromise = null;

    const applyUiCapabilities = function () {
      if (main.store && typeof main.store.set === "function") {
        const currentSystemInfo = main.store.get().diagnosticsSystemInfo;
        main.store.set({
          diagnosticsSystemInfo: {
            ...currentSystemInfo,
            providerInfoLoaded: true,
            sing_box_extended: uiCapabilities.singBoxExtended ? 1 : 0,
            sing_box_tiny: uiCapabilities.singBoxTiny ? 1 : 0,
            sing_box_tailscale: uiCapabilities.singBoxTailscale ? 1 : 0,
          },
        });
      }
    };

    const updateUiCapabilities = function (data) {
      uiCapabilities.loaded = true;
      uiCapabilities.singBoxExtended = Boolean(
        Number(data?.sing_box_extended) === 1,
      );
      uiCapabilities.singBoxTiny = Boolean(Number(data?.sing_box_tiny) === 1);
      uiCapabilities.singBoxTailscale =
        typeof data?.sing_box_tailscale === "undefined"
          ? true
          : Boolean(Number(data.sing_box_tailscale) === 1);
      applyUiCapabilities();

      return uiCapabilities;
    };

    const applyUiState = function (data) {
      const result = updateUiCapabilities(data?.capabilities || data || {});

      if (typeof main.applyUiStateToStore === "function" && data?.service) {
        main.applyUiStateToStore(data);
      } else if (
        main.store &&
        typeof main.store.set === "function" &&
        data?.service
      ) {
        main.store.set({
          servicesInfoWidget: {
            loading: false,
            failed: false,
            data: {
              singbox: Number(data.service.sing_box?.running) || 0,
              forkopRunning: Number(data.service.forkop?.running) || 0,
              forkopEnabled: Number(data.service.forkop?.enabled) || 0,
              forkopStatus: data.service.forkop?.status || "",
            },
          },
        });
      }

      return result;
    };

    const loadUiCapabilities = function () {
      if (uiCapabilities.loaded) {
        return Promise.resolve(uiCapabilities);
      }

      if (uiCapabilitiesPromise) {
        return uiCapabilitiesPromise;
      }

      uiCapabilitiesPromise = main.ForkopShellMethods.getUiCapabilities()
        .then((response) => {
          if (!response?.success) {
            throw new Error("UI capabilities request failed");
          }

          return updateUiCapabilities(response.data);
        })
        .catch((error) => {
          console.warn("Failed to load Forkop UI capabilities", error);
          return main.ForkopShellMethods.getUiState()
            .then((response) => {
              if (!response?.success) {
                throw new Error("UI state request failed");
              }

              return applyUiState(response.data);
            })
            .catch((fallbackError) => {
              console.warn("Failed to load Forkop UI state", fallbackError);
              return uiCapabilities;
            });
        })
        .finally(() => {
          uiCapabilitiesPromise = null;
        });

      return uiCapabilitiesPromise;
    };
    const forkopMap = new form.Map(UCI_PACKAGE, _("Forkop X Settings"), null);
    whatsapp.configureMap(forkopMap);
    forkopMap.tabbed = true;

    const rulesSection = forkopMap.section(
      form.GridSection,
      "section",
      _("Sections"),
      _("Drag rows to change priority. The rule at the top is checked first."),
    );
    configureGridSection(
      rulesSection,
      "section",
      _("Section"),
      _("Add a section"),
    );
    section.configureSectionSection(rulesSection);
    section.createSectionContent(rulesSection);

    const settingsSection = forkopMap.section(
      form.TypedSection,
      "settings",
      _("Settings"),
    );
    settingsSection.anonymous = true;
    settingsSection.addremove = false;
    settingsSection.cfgsections = function () {
      return ["settings"];
    };
    settings.createSettingsContent(settingsSection);

    const diagnosticSection = forkopMap.section(
      form.TypedSection,
      "diagnostic",
      _("Diagnostics"),
    );
    diagnosticSection.anonymous = true;
    diagnosticSection.addremove = false;
    diagnosticSection.cfgsections = function () {
      return ["diagnostic"];
    };
    diagnostic.createDiagnosticContent(diagnosticSection);

    const dashboardSection = forkopMap.section(
      form.TypedSection,
      "dashboard",
      _("Dashboard"),
    );
    dashboardSection.anonymous = true;
    dashboardSection.addremove = false;
    dashboardSection.cfgsections = function () {
      return ["dashboard"];
    };
    dashboard.createDashboardContent(dashboardSection);

    const monitoringSection = forkopMap.section(
      form.TypedSection,
      "monitoring",
      _("Monitoring"),
    );
    monitoringSection.anonymous = true;
    monitoringSection.addremove = false;
    monitoringSection.cfgsections = function () {
      return ["monitoring"];
    };
    monitoring.createMonitoringContent(monitoringSection);

    const updatesSection = forkopMap.section(
      form.TypedSection,
      "updates",
      _("Components"),
    );
    updatesSection.anonymous = true;
    updatesSection.addremove = false;
    updatesSection.cfgsections = function () {
      return ["updates"];
    };
    updates.createUpdatesContent(updatesSection);

    const tailscaleSection = forkopMap.section(
      form.TypedSection,
      "tailscale_native",
      "Tailscale",
    );
    tailscaleSection.anonymous = true;
    tailscaleSection.addremove = false;
    tailscaleSection.cfgsections = () => ["tailscale_native"];
    tailscale.createTailscaleContent(tailscaleSection);

    const rendered = await forkopMap.render();
    // Capability probes must not hold LuCI's entire view behind Loading view.
    // Start after rendering; rule editors share this request when opened.
    window.setTimeout(() => {
      void loadUiCapabilities().catch(() => null);
    }, 0);
    main.coreService({
      waitForLogWatcherStart: loadUiCapabilities,
      logWatcherStartDelayMs: 5000,
    });

    return rendered;
  },
};

return view.extend(EntryPoint);
