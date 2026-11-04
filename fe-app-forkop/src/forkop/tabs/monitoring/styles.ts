// language=CSS
import { FORKOP_UCI_PACKAGE as FORKOP_CBI_PREFIX } from '../../../constants';

export const styles = `
#cbi-${FORKOP_CBI_PREFIX}-monitoring-_mount_node {
    margin: 16px 0 22px;
    padding: 0;
    display: block;
    width: 100%;
    max-width: none;
    min-width: 0;
    box-sizing: border-box;
}

#cbi-${FORKOP_CBI_PREFIX}-monitoring-_mount_node > .cbi-value-title {
    display: none;
}

#cbi-${FORKOP_CBI_PREFIX}-monitoring-_mount_node > .cbi-value-field {
    margin-left: 0;
    width: 100%;
    max-width: none;
    min-width: 0;
    flex: 1 1 100%;
    float: none;
    box-sizing: border-box;
}

#cbi-${FORKOP_CBI_PREFIX}-monitoring-_mount_node > div {
    width: 100%;
}

#cbi-${FORKOP_CBI_PREFIX}-monitoring > h3 {
    display: none;
}

.fkp_monitoring-page {
    --fkp-monitoring-control-height: 34px;
    --fkp-monitoring-row-action-size: 24px;
    --fkp-monitoring-divider-color: rgba(127, 127, 127, 0.22);
    --fkp-monitoring-soft-bg: rgba(127, 127, 127, 0.08);
    --fkp-monitoring-soft-bg-hover: rgba(127, 127, 127, 0.14);
    --fkp-monitoring-danger-color: var(--error-color-medium, #d32f2f);
    --fkp-monitoring-success-color: var(--success-color-medium, #2e7d32);
    --fkp-monitoring-paused-color: var(--primary-color-high, #1976d2);

    width: 100%;
    min-width: 0;
}

.fkp_monitoring-page__panel {
    margin-top: 0;
    border: 0;
    border-radius: 0;
    padding: 0;
    background: transparent;
    box-sizing: border-box;
    width: 100%;
    min-width: 0;
}

.fkp_monitoring-page .btn.fkp_monitoring-page__icon-button {
    width: 32px;
    height: 32px;
    min-width: 32px;
    min-height: 32px;
    padding: 0;
    box-sizing: border-box;
    display: flex;
    align-items: center;
    justify-content: center;
    flex: 0 0 auto;
    line-height: 1;
    margin: 0;
    border: 1px solid var(--fkp-monitoring-divider-color) !important;
    border-radius: 6px;
    background: var(--fkp-monitoring-soft-bg) !important;
    color: var(--text-color-medium) !important;
    box-shadow: none;
}

.fkp_monitoring-page .btn.fkp_monitoring-page__icon-button:hover:not(:disabled) {
    background: var(--fkp-monitoring-soft-bg-hover) !important;
    color: var(--text-color-high) !important;
}

.fkp_monitoring-page .btn.fkp_monitoring-page__icon-button--active {
    background: rgba(25, 118, 210, 0.16) !important;
    color: var(--primary-color-high, #1976d2) !important;
}

.fkp_monitoring-page .btn.fkp_monitoring-page__icon-button:disabled {
    opacity: 0.45;
    cursor: not-allowed;
}

.fkp_monitoring-page #monitoring-close-all.btn.fkp_monitoring-page__icon-button {
    order: 2;
    border-color: rgba(217, 83, 79, 0.4) !important;
    background: transparent !important;
    color: var(--fkp-monitoring-danger-color) !important;
}

.fkp_monitoring-page #monitoring-close-all.btn.fkp_monitoring-page__icon-button:hover:not(:disabled) {
    border-color: rgba(217, 83, 79, 0.6) !important;
    background: transparent !important;
    color: color-mix(in srgb, var(--fkp-monitoring-danger-color) 70%, white) !important;
}

.fkp_monitoring-page #monitoring-pause-toggle.btn.fkp_monitoring-page__icon-button,
.fkp_monitoring-page #monitoring-pause-toggle.btn.fkp_monitoring-page__icon-button--active {
    order: 1;
    border-color: rgba(128, 128, 128, 0.3) !important;
    background: transparent !important;
    color: var(--text-color-medium, #888) !important;
}

.fkp_monitoring-page #monitoring-pause-toggle.btn.fkp_monitoring-page__icon-button:hover:not(:disabled),
.fkp_monitoring-page #monitoring-pause-toggle.btn.fkp_monitoring-page__icon-button--active:hover:not(:disabled) {
    border-color: rgba(128, 128, 128, 0.6) !important;
    background: transparent !important;
    color: var(--text-color-high, #eee) !important;
}

.fkp_monitoring-page__icon-button svg,
.fkp_monitoring-page__row-action svg {
    width: 16px;
    height: 16px;
    display: block;
    flex: 0 0 auto;
}

.fkp_monitoring-page__controls {
    display: flex;
    flex-wrap: wrap;
    align-items: center;
    justify-content: space-between;
    gap: 16px;
    margin-bottom: 12px;
    width: 100%;
    min-width: 0;
}

.fkp_monitoring-page__actions {
    display: flex;
    align-items: center;
    justify-content: flex-end;
    gap: 8px;
    min-width: 0;
}

.fkp_monitoring-page__tabs {
    display: inline-flex;
    align-items: center;
    gap: 2px;
    width: max-content;
    padding: 2px;
    border: 1px solid var(--fkp-monitoring-divider-color);
    border-radius: 6px;
    background: var(--fkp-monitoring-soft-bg);
    box-sizing: border-box;
}

.fkp_monitoring-page .btn.fkp_monitoring-page__tab {
    height: calc(var(--fkp-monitoring-control-height) - 6px);
    min-height: calc(var(--fkp-monitoring-control-height) - 6px);
    margin: 0;
    padding: 0 12px;
    border: 0 !important;
    border-radius: 4px;
    background: transparent !important;
    color: var(--text-color-medium) !important;
    box-shadow: none;
    display: inline-flex;
    align-items: center;
    justify-content: center;
    gap: 8px;
    font-weight: 600;
    line-height: 1;
}

.fkp_monitoring-page .btn.fkp_monitoring-page__tab:hover {
    background: var(--fkp-monitoring-soft-bg-hover) !important;
    color: var(--text-color-high) !important;
}

.fkp_monitoring-page .btn.fkp_monitoring-page__tab--active {
    background: rgba(25, 118, 210, 0.16) !important;
    color: var(--primary-color-high, #1976d2) !important;
    font-weight: 700;
}

.fkp_monitoring-page__tab-label {
    display: inline-block;
}

.fkp_monitoring-page__tab-badge {
    min-width: 18px;
    height: 18px;
    padding: 0 6px;
    border-radius: 999px;
    background: rgba(127, 127, 127, 0.22);
    color: var(--text-color-medium);
    display: inline-flex;
    align-items: center;
    justify-content: center;
    box-sizing: border-box;
    font-size: 12px;
    font-weight: 700;
    line-height: 1;
}

.fkp_monitoring-page__tab--active .fkp_monitoring-page__tab-badge {
    background: rgba(25, 118, 210, 0.22);
    color: var(--primary-color-high, #1976d2);
}

.fkp_monitoring-page__filters {
    display: flex;
    flex: 1 1 auto;
    flex-wrap: wrap;
    align-items: center;
    justify-content: flex-start;
    gap: 12px;
    min-width: 0;
}

.fkp_monitoring-page__device-filter {
    width: min(220px, 100%);
    min-width: 0;
    height: var(--fkp-monitoring-control-height) !important;
    min-height: var(--fkp-monitoring-control-height) !important;
    padding-top: 0 !important;
    padding-bottom: 0 !important;
    margin: 0 !important;
    box-sizing: border-box;
    line-height: calc(var(--fkp-monitoring-control-height) - 2px) !important;
}

.fkp_monitoring-page__search {
    position: relative;
    display: flex;
    align-items: center;
    width: min(320px, 100%);
    min-width: 0;
    height: var(--fkp-monitoring-control-height);
    margin: 0;
}

.fkp_monitoring-page__search-icon {
    position: absolute;
    left: 8px;
    width: 16px;
    height: 16px;
    color: var(--text-color-medium);
    pointer-events: none;
}

.fkp_monitoring-page__search-icon svg {
    width: 16px;
    height: 16px;
    display: block;
}

.fkp_monitoring-page__search-input {
    width: 100%;
    height: var(--fkp-monitoring-control-height) !important;
    min-height: var(--fkp-monitoring-control-height) !important;
    padding-left: 30px !important;
    padding-top: 0 !important;
    padding-bottom: 0 !important;
    margin: 0 !important;
    box-sizing: border-box;
    line-height: calc(var(--fkp-monitoring-control-height) - 2px) !important;
}

.fkp_monitoring-page__body {
    margin-top: 0;
    width: 100%;
    min-width: 0;
}

.fkp_monitoring-page__table-wrap {
    width: 100%;
    min-width: 0;
    overflow-x: auto;
    margin-bottom: 0;
}

.fkp_monitoring-page__table {
    width: 100%;
    min-width: 840px;
    margin-bottom: 0;
}

.fkp_monitoring-page__row {
    display: grid;
    grid-template-columns: minmax(0, 28fr) minmax(0, 6fr) minmax(0, 16fr) minmax(0, 8fr) minmax(0, 9.5fr) minmax(0, 8.5fr) minmax(0, 16fr) minmax(0, 8fr);
    min-width: 0;
}

.fkp_monitoring-page__header-cell,
.fkp_monitoring-page__cell {
    padding: 8px 6px;
    border-bottom: 1px solid var(--fkp-monitoring-divider-color);
    box-sizing: border-box;
    text-align: left;
    min-width: 0;
    overflow: hidden;
    white-space: nowrap;
}

.fkp_monitoring-page__cell {
    display: flex;
    align-items: center;
}

.fkp_monitoring-page__cell-content {
    width: 100%;
}

.fkp_monitoring-page__cell-label {
    display: none;
}

.fkp_monitoring-page__header-cell {
    color: var(--text-color-medium);
    font-size: 11px;
    font-weight: 600;
    text-transform: uppercase;
    white-space: nowrap;
    border-bottom-color: rgba(127, 127, 127, 0.32);
}

.fkp_monitoring-page__rows > .fkp_monitoring-page__row:last-child > .fkp_monitoring-page__cell {
    border-bottom: 0;
}

.fkp_monitoring-page__cell:last-child {
    padding-top: 0;
    padding-bottom: 0;
}

.fkp_monitoring-page__header-cell:nth-child(4),
.fkp_monitoring-page__cell:nth-child(4),
.fkp_monitoring-page__header-cell:nth-child(5),
.fkp_monitoring-page__cell:nth-child(5),
.fkp_monitoring-page__header-cell:nth-child(6),
.fkp_monitoring-page__cell:nth-child(6) {
    text-align: right;
}

.fkp_monitoring-page__header-cell:nth-child(7),
.fkp_monitoring-page__cell:nth-child(7) {
    text-align: left;
}

.fkp_monitoring-page__header-cell:last-child,
.fkp_monitoring-page__cell:last-child {
    text-align: center;
}

.fkp_monitoring-page__value {
    display: block;
    max-width: 100%;
    min-width: 0;
    overflow: hidden;
    text-overflow: ellipsis;
    white-space: nowrap;
    text-align: left;
    line-height: 1.3;
    color: var(--text-color-high);
    font-size: 13px;
    user-select: text;
}

.fkp_monitoring-page__cell-content {
    min-width: 0;
    max-width: 100%;
}

.fkp_monitoring-page__source-value {
    display: flex;
    align-items: baseline;
    justify-content: flex-start;
    gap: 5px;
}

.fkp_monitoring-page__source-name {
    min-width: 0;
    overflow: hidden;
    text-overflow: ellipsis;
    white-space: nowrap;
}

.fkp_monitoring-page__source-ip {
    flex: 0 1 auto;
    min-width: 0;
    overflow: hidden;
    text-overflow: ellipsis;
    white-space: nowrap;
    color: var(--text-color-medium);
    font-size: 12px;
}

.fkp_monitoring-page__source-value--ip-only {
    color: var(--text-color-high);
}

.fkp_monitoring-page__cell-main {
    color: var(--text-color-high);
    font-weight: 600;
    line-height: 1.25;
}

.fkp_monitoring-page__cell-secondary {
    margin-top: 2px;
    color: var(--text-color-medium);
    font-size: 12px;
    line-height: 1.25;
}

.fkp_monitoring-page__reason {
    display: block;
    margin-top: 4px;
    max-width: 280px;
    white-space: normal;
    overflow-wrap: anywhere;
    color: var(--text-color-medium, #bbb);
    font-size: 11px;
}

.fkp_monitoring-page__route {
    display: inline-block;
    width: auto;
    padding: 2px 6px;
    border-radius: 4px;
    background: rgba(128, 128, 128, 0.15);
    color: var(--text-color-high, #eee);
    font-size: 11px;
    font-weight: 500;
}

.fkp_monitoring-page__network {
    background: transparent;
    border: 0;
    padding: 0;
    color: var(--text-color-medium, #bbb);
    font-family: inherit;
    font-size: 13px;
    text-transform: lowercase;
}

.fkp_monitoring-page__cell:nth-child(4) .fkp_monitoring-page__value,
.fkp_monitoring-page__cell:nth-child(5) .fkp_monitoring-page__value,
.fkp_monitoring-page__cell:nth-child(6) .fkp_monitoring-page__value {
    color: var(--text-color-medium, #bbb);
    font-family: inherit;
    text-align: right;
}

.fkp_monitoring-page .btn.fkp_monitoring-page__row-action {
    width: var(--fkp-monitoring-row-action-size);
    height: var(--fkp-monitoring-row-action-size);
    min-width: var(--fkp-monitoring-row-action-size);
    min-height: var(--fkp-monitoring-row-action-size);
    padding: 0;
    box-sizing: border-box;
    display: inline-flex;
    align-items: center;
    justify-content: center;
    line-height: 1;
    margin: 0;
    border: 0 !important;
    border-radius: 999px;
    background: transparent !important;
    color: var(--fkp-monitoring-danger-color) !important;
    box-shadow: none;
    cursor: pointer;
}

.fkp_monitoring-page__row-action svg {
    width: 14px;
    height: 14px;
}

.fkp_monitoring-page .btn.fkp_monitoring-page__row-action:hover:not(:disabled) {
    background: var(--fkp-monitoring-soft-bg-hover) !important;
    color: var(--fkp-monitoring-danger-color) !important;
}

.fkp_monitoring-page .btn.fkp_monitoring-page__row-action:disabled {
    opacity: 0.45;
    cursor: wait;
}

.fkp_monitoring-page__row--closing {
    opacity: 0.55;
}

.fkp_monitoring-page__state {
    min-height: 90px;
    width: 100%;
    display: flex;
    align-items: center;
    justify-content: center;
    color: var(--text-color-medium);
    text-align: center;
    box-sizing: border-box;
}

.fkp_monitoring-page__state-cell {
    padding: 0 !important;
    grid-column: 1 / -1;
}

.fkp_monitoring-page__state--error {
    color: var(--error-color-medium, #d32f2f);
}

@media (max-width: 900px) {
    .fkp_monitoring-page {
        --fkp-monitoring-control-height: 40px;
        --fkp-monitoring-row-action-size: 40px;
    }

    .fkp_monitoring-page__controls {
        display: grid;
        grid-template-columns: minmax(0, 1fr) auto;
        align-items: center;
        gap: 10px;
    }

    .fkp_monitoring-page__tabs {
        grid-column: 1 / -1;
        max-width: 100%;
    }

    .fkp_monitoring-page__filters {
        display: grid;
        grid-template-columns: minmax(0, 1fr) minmax(0, 1fr);
        gap: 10px;
    }

    .fkp_monitoring-page__device-filter,
    .fkp_monitoring-page__search {
        width: 100%;
        max-width: none;
    }

    .fkp_monitoring-page .btn.fkp_monitoring-page__icon-button {
        width: 40px;
        height: 40px;
        min-width: 40px;
        min-height: 40px;
    }

    .fkp_monitoring-page__table {
        min-width: 0;
    }

    .fkp_monitoring-page__head {
        display: none;
    }

    .fkp_monitoring-page__table,
    .fkp_monitoring-page__rows,
    .fkp_monitoring-page__row,
    .fkp_monitoring-page__cell {
        display: block;
        width: 100%;
    }

    .fkp_monitoring-page__row {
        border: 1px var(--background-color-low, lightgray) solid;
        border-radius: 4px;
        padding: 8px;
        box-sizing: border-box;
        margin-bottom: 8px;
    }

    .fkp_monitoring-page__cell {
        display: grid;
        grid-template-columns: minmax(92px, 34%) minmax(0, 1fr);
        gap: 8px;
        border: 0;
        border-bottom: 1px solid var(--fkp-monitoring-divider-color);
        padding: 4px 0;
        box-sizing: border-box;
        text-align: left;
    }

    .fkp_monitoring-page__cell-label {
        display: block;
        text-align: left;
        color: var(--text-color-medium);
        font-weight: 700;
        min-width: 0;
        white-space: normal;
        overflow-wrap: anywhere;
    }

    .fkp_monitoring-page__cell:last-child {
        grid-template-columns: minmax(92px, 34%) minmax(0, 1fr);
        align-items: center;
        border-bottom: 0;
        min-height: var(--fkp-monitoring-row-action-size);
        padding: 0;
    }

    .fkp_monitoring-page__cell .fkp_monitoring-page__value {
        white-space: normal;
        overflow-wrap: anywhere;
        text-align: left;
    }

    .fkp_monitoring-page__cell > .fkp_monitoring-page__cell-content,
    .fkp_monitoring-page__cell > .fkp_monitoring-page__cell-content > .fkp_monitoring-page__value {
        text-align: left;
    }

    .fkp_monitoring-page__source-value {
        flex-wrap: wrap;
        justify-content: flex-start;
    }

    .fkp_monitoring-page__source-name,
    .fkp_monitoring-page__source-ip {
        white-space: normal;
        overflow-wrap: anywhere;
    }

    .fkp_monitoring-page__reason {
        max-width: 100%;
    }

    .fkp_monitoring-page__table .fkp_monitoring-page__state-cell {
        display: block;
    }

}

@media (max-width: 520px) {
    .fkp_monitoring-page__filters {
        grid-column: 1 / -1;
        grid-template-columns: minmax(0, 1fr);
    }

    .fkp_monitoring-page__actions {
        grid-column: 2;
        grid-row: 1;
    }

    .fkp_monitoring-page__tabs {
        grid-column: 1;
        grid-row: 1;
        display: grid;
        grid-template-columns: minmax(0, 1fr) minmax(0, 1fr);
        width: 100%;
        min-width: 0;
    }

    .fkp_monitoring-page .btn.fkp_monitoring-page__tab {
        height: auto;
        min-width: 0;
        min-height: var(--fkp-monitoring-control-height);
        padding: 5px;
        gap: 4px;
        flex-wrap: wrap;
        font-size: 12px;
    }

    .fkp_monitoring-page__tab-label {
        min-width: 0;
        overflow-wrap: anywhere;
    }

    .fkp_monitoring-page__device-filter,
    .fkp_monitoring-page__search-input {
        font-size: 16px;
    }

    .fkp_monitoring-page__cell,
    .fkp_monitoring-page__cell:last-child {
        grid-template-columns: minmax(92px, 30%) minmax(0, 1fr);
        gap: 8px;
    }

    .fkp_monitoring-page__source-value {
        align-items: flex-start;
        flex-direction: column;
        gap: 2px;
    }
}
`;
