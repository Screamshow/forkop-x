import { renderLoaderCircleIcon24, renderInfoIcon24 } from '../../../../icons';
import { svgEl } from '../../../../helpers';
import { prettyBytes } from '../../../../helpers/prettyBytes';
import { Forkop } from '../../../types';
import { renderFlagEmojis } from './renderFlagEmojis';
import { getOutboundFooterLabel } from './getOutboundFooterLabel';
import { getDashboardLatencyClass } from '../latencyUpdate';

interface IRenderSectionsProps {
  loading: boolean;
  failed: boolean;
  section: Forkop.OutboundGroup;
  onTestLatency: (tag: string | string[]) => void;
  onChooseOutbound: (
    sectionName: string,
    selector: string,
    tag: string,
  ) => void;
  onShowUrlTestInfo: (outbound: Forkop.Outbound) => void;
  onShowPriorityInfo: (outbound: Forkop.Outbound) => void;
  onUpdateSubscription: (section: Forkop.OutboundGroup) => void;
  latencyFetching: boolean;
  latencyProgress?: Forkop.LatencyActionProgress;
  subscriptionUpdating: boolean;
  selectorSwitchingTag?: string;
  isPriorityMembersExpanded: (outbound: Forkop.Outbound) => boolean;
  onPriorityMembersToggle: (outbound: Forkop.Outbound, open: boolean) => void;
}

function renderFailedState() {
  return E(
    'div',
    {
      class: 'fkp_dashboard-page__outbound-section centered',
      style: 'height: 127px',
    },
    E('span', {}, [E('span', {}, _('Dashboard currently unavailable'))]),
  );
}

function renderLoadingState() {
  return E('div', {
    id: 'dashboard-sections-grid-skeleton',
    class: 'fkp_dashboard-page__outbound-section skeleton',
    style: 'height: 127px',
  });
}

function isValidHttpUrl(url?: string) {
  return Boolean(url && /^https?:\/\/\S+$/i.test(url));
}

function formatBytes(value?: number) {
  if (typeof value !== 'number' || !Number.isFinite(value) || value < 0) {
    return undefined;
  }

  return prettyBytes(value);
}

function formatDate(seconds?: number) {
  if (
    typeof seconds !== 'number' ||
    !Number.isFinite(seconds) ||
    seconds <= 0
  ) {
    return undefined;
  }

  const date = new Date(seconds * 1000);
  if (Number.isNaN(date.getTime())) {
    return undefined;
  }

  return date.toLocaleDateString(undefined, {
    year: 'numeric',
    month: '2-digit',
    day: '2-digit',
  });
}

function renderMetadataAction(label: string, url?: string) {
  if (!isValidHttpUrl(url)) {
    return undefined;
  }

  return E(
    'a',
    {
      class: 'btn fkp_dashboard-page__subscription-meta__action',
      href: url,
      target: '_blank',
      rel: 'noopener noreferrer',
      title: label,
      'aria-label': label,
    },
    label,
  );
}

function renderSubscriptionMetadata(
  metadata: Forkop.SubscriptionMetadata | undefined,
) {
  if (!metadata || Object.keys(metadata).length <= 1) {
    return undefined;
  }

  const title = metadata.title || metadata.fileName;
  const traffic = metadata.traffic;
  const used = formatBytes(traffic?.used) || '0 B';
  const total = traffic?.isUnlimited
    ? '∞'
    : formatBytes(traffic?.total) || '0 B';
  const expire = formatDate(metadata.expire);
  const refillDate = formatDate(metadata.refillDate);

  const rows = [
    traffic
      ? {
          label: _('Traffic'),
          value: `${used} / ${total}`,
        }
      : undefined,
    expire ? { label: _('Expires'), value: expire } : undefined,
    refillDate ? { label: _('Refill'), value: refillDate } : undefined,
  ].filter(Boolean) as { label: string; value: string }[];

  const actions = [
    renderMetadataAction(_('Profile'), metadata.webPageUrl),
    renderMetadataAction(_('Support'), metadata.supportUrl),
    renderMetadataAction(_('More details'), metadata.announceUrl),
  ].filter(Boolean) as HTMLElement[];

  return E('div', { class: 'fkp_dashboard-page__subscription-meta' }, [
    E('div', { class: 'fkp_dashboard-page__subscription-meta__main' }, [
      E(
        'div',
        { class: 'fkp_dashboard-page__subscription-meta__heading' },
        _('Subscription info:'),
      ),
      title
        ? E(
            'div',
            { class: 'fkp_dashboard-page__subscription-meta__title' },
            title,
          )
        : '',
      rows.length
        ? E(
            'div',
            { class: 'fkp_dashboard-page__subscription-meta__facts' },
            rows.map((row) =>
              E(
                'div',
                { class: 'fkp_dashboard-page__subscription-meta__fact' },
                [
                  E(
                    'span',
                    {
                      class: 'fkp_dashboard-page__subscription-meta__fact-key',
                    },
                    row.label,
                  ),
                  E(
                    'span',
                    {
                      class:
                        'fkp_dashboard-page__subscription-meta__fact-value',
                    },
                    row.value,
                  ),
                ],
              ),
            ),
          )
        : '',
      actions.length
        ? E(
            'div',
            { class: 'fkp_dashboard-page__subscription-meta__actions' },
            actions,
          )
        : '',
    ]),
    metadata.announce
      ? E(
          'blockquote',
          { class: 'fkp_dashboard-page__subscription-meta__announce' },
          metadata.announce,
        )
      : '',
  ]);
}

function renderSubscriptionUpdateAction(
  section: Forkop.OutboundGroup,
  subscriptionUpdating: boolean,
  onUpdateSubscription: (section: Forkop.OutboundGroup) => void,
) {
  if (!section.subscriptionSourceCount) {
    return undefined;
  }

  return E(
    'button',
    {
      type: 'button',
      class: 'btn fkp_dashboard-page__outbound-section__subscription-update',
      'aria-label': _('Update all subscriptions'),
      disabled: subscriptionUpdating ? true : undefined,
      click: (event: MouseEvent) => {
        event.preventDefault();
        event.stopPropagation();
        if (subscriptionUpdating) {
          return;
        }

        onUpdateSubscription(section);
      },
    },
    subscriptionUpdating
      ? [renderLoaderCircleIcon24(), _('Update all subscriptions')]
      : _('Update all subscriptions'),
  );
}

export function getLatencyTestLabel(
  latencyProgress?: Forkop.LatencyActionProgress,
) {
  const total = Math.trunc(Number(latencyProgress?.total ?? 0));
  if (!Number.isFinite(total) || total <= 0) {
    return _('Test latency');
  }

  const completedValue = Number(latencyProgress?.completed ?? 0);
  const completed = Number.isFinite(completedValue)
    ? Math.trunc(completedValue)
    : 0;

  return `${_('Test latency')}: ${Math.min(
    Math.max(0, completed),
    total,
  )}/${total}`;
}

function renderDefaultState({
  section,
  onChooseOutbound,
  onShowUrlTestInfo,
  onShowPriorityInfo,
  onTestLatency,
  onUpdateSubscription,
  latencyFetching,
  latencyProgress,
  subscriptionUpdating,
  selectorSwitchingTag,
  isPriorityMembersExpanded,
  onPriorityMembersToggle,
}: IRenderSectionsProps) {
  function renderPriorityMembers(outbound: Forkop.Outbound) {
    const members = outbound.priorityInfo?.outbounds || [];

    if (members.length === 0) {
      return undefined;
    }

    let previousLevel = -1;
    const content: HTMLElement[] = [];

    members.forEach((member, index) => {
      if (member.levelIndex !== previousLevel) {
        previousLevel = member.levelIndex;
        content.push(
          E(
            'div',
            { class: 'fkp_dashboard-page__priority-members__level' },
            `${_('Priority')} #${member.levelIndex + 1}: ${member.levelName}`,
          ),
        );
      }

      content.push(
        E(
          'div',
          {
            class: [
              'fkp_dashboard-page__priority-members__row',
              member.selected
                ? 'fkp_dashboard-page__priority-members__row--selected'
                : '',
            ]
              .filter(Boolean)
              .join(' '),
          },
          [
            E(
              'span',
              { class: 'fkp_dashboard-page__priority-members__order' },
              String(index + 1),
            ),
            E(
              'span',
              { class: 'fkp_dashboard-page__priority-members__name' },
              renderFlagEmojis(member.displayName),
            ),
            E(
              'span',
              {
                class: member.latency
                  ? 'fkp_dashboard-page__outbound-grid__item__latency--green'
                  : 'fkp_dashboard-page__outbound-grid__item__latency--empty',
              },
              member.latency ? `${member.latency}ms` : 'N/A',
            ),
          ],
        ),
      );
    });

    return E(
      'details',
      {
        class: 'fkp_dashboard-page__priority-members',
        open: isPriorityMembersExpanded(outbound),
        click: (event: Event) => event.stopPropagation(),
        ontoggle: (event: Event) => {
          const details = event.currentTarget as HTMLDetailsElement;
          onPriorityMembersToggle(outbound, details.open);
        },
      },
      [
        E('summary', {}, `${_('Nodes')}: ${members.length}`),
        E(
          'div',
          { class: 'fkp_dashboard-page__priority-members__list' },
          content,
        ),
      ],
    );
  }

  function testLatency() {
    if (section.withTagSelect) {
      return onTestLatency(
        section.latencyTestCodes?.length
          ? section.latencyTestCodes
          : section.latencyTestCode || section.code,
      );
    }

    if (section.outbounds.length) {
      return onTestLatency(section.outbounds[0].code);
    }
  }

  function renderOutbound(outbound: Forkop.Outbound) {
    const footerLabel = getOutboundFooterLabel(outbound);
    const priorityMembers = renderPriorityMembers(outbound);
    const selectorSwitching = Boolean(selectorSwitchingTag);
    const outboundSwitching = selectorSwitchingTag === outbound.code;
    const canChooseOutbound =
      section.withTagSelect &&
      outbound.runtimeAvailable !== false &&
      !selectorSwitching &&
      !outbound.selected;
    const className = [
      'fkp_dashboard-page__outbound-grid__item',
      outbound.selected
        ? 'fkp_dashboard-page__outbound-grid__item--active'
        : '',
      canChooseOutbound
        ? 'fkp_dashboard-page__outbound-grid__item--selectable'
        : '',
      section.withTagSelect && !canChooseOutbound
        ? 'fkp_dashboard-page__outbound-grid__item--disabled'
        : '',
      outboundSwitching
        ? 'fkp_dashboard-page__outbound-grid__item--switching'
        : '',
    ]
      .filter(Boolean)
      .join(' ');
    return E(
      'div',
      {
        class: className,
        'aria-busy': outboundSwitching ? 'true' : undefined,
        'aria-disabled':
          section.withTagSelect && !canChooseOutbound ? 'true' : undefined,
        click: () =>
          canChooseOutbound &&
          onChooseOutbound(section.sectionName, section.code, outbound.code),
      },
      [
        ...(outboundSwitching
          ? [
              svgEl(
                'svg',
                { class: 'fkp_dashboard-page__outbound-grid__item__snake' },
                [
                  svgEl('rect', {
                    width: '100%',
                    height: '100%',
                    fill: 'none',
                    rx: 4,
                    ry: 4,
                    pathLength: 100,
                  }),
                ],
              ),
            ]
          : []),
        E('div', { class: 'fkp_dashboard-page__outbound-grid__item__header' }, [
          E('b', {}, renderFlagEmojis(outbound.displayName)),
          ...(outbound.urlTestInfo
            ? [
                E(
                  'button',
                  {
                    type: 'button',
                    class:
                      'btn fkp_dashboard-page__outbound-grid__item__copy-button',
                    title: _('URLTest details'),
                    'aria-label': _('URLTest details'),
                    click: (event: MouseEvent) => {
                      event.stopPropagation();
                      onShowUrlTestInfo(outbound);
                    },
                  },
                  renderInfoIcon24(),
                ),
              ]
            : []),
          ...(outbound.priorityInfo
            ? [
                E(
                  'button',
                  {
                    type: 'button',
                    class:
                      'btn fkp_dashboard-page__outbound-grid__item__copy-button',
                    title: _('Priority details'),
                    'aria-label': _('Priority details'),
                    click: (event: MouseEvent) => {
                      event.stopPropagation();
                      onShowPriorityInfo(outbound);
                    },
                  },
                  renderInfoIcon24(),
                ),
              ]
            : []),
        ]),
        E('div', { class: 'fkp_dashboard-page__outbound-grid__item__footer' }, [
          E(
            'div',
            { class: 'fkp_dashboard-page__outbound-grid__item__type' },
            renderFlagEmojis(footerLabel),
          ),
          E(
            'div',
            {
              class: getDashboardLatencyClass(outbound.latency),
              'data-latency-section': section.sectionName,
              'data-latency-outbound': outbound.code,
            },
            outbound.latency ? `${outbound.latency}ms` : 'N/A',
          ),
        ]),
        ...(priorityMembers ? [priorityMembers] : []),
      ],
    );
  }

  const metadataNodes = (section.subscriptionMetadata || [])
    .map((metadata) => renderSubscriptionMetadata(metadata))
    .filter(Boolean) as HTMLElement[];
  const subscriptionUpdateAction = renderSubscriptionUpdateAction(
    section,
    subscriptionUpdating,
    onUpdateSubscription,
  );

  return E('div', { class: 'fkp_dashboard-page__outbound-section' }, [
    // Title with test latency
    E('div', { class: 'fkp_dashboard-page__outbound-section__title-section' }, [
      E(
        'div',
        {
          class: 'fkp_dashboard-page__outbound-section__title-section__title',
        },
        section.displayName,
      ),
      E(
        'div',
        {
          class: 'fkp_dashboard-page__outbound-section__title-section__actions',
        },
        [
          ...(subscriptionUpdateAction ? [subscriptionUpdateAction] : []),
          E(
            'button',
            {
              type: 'button',
              class: 'btn dashboard-sections-grid-item-test-latency',
              'data-latency-section': section.sectionName,
              disabled: latencyFetching ? true : undefined,
              click: (event: MouseEvent) => {
                event.preventDefault();
                event.stopPropagation();
                if (latencyFetching) {
                  return;
                }

                testLatency();
              },
            },
            latencyFetching
              ? [
                  renderLoaderCircleIcon24(),
                  E(
                    'span',
                    {
                      class: 'dashboard-sections-grid-item-test-latency__label',
                    },
                    getLatencyTestLabel(latencyProgress),
                  ),
                ]
              : E(
                  'span',
                  {
                    class: 'dashboard-sections-grid-item-test-latency__label',
                  },
                  _('Test latency'),
                ),
          ),
        ],
      ),
    ]),
    ...(section.skippedSubscriptionOutbounds?.length
      ? [
          E('div', { class: 'alert-message warning' }, [
            E('strong', {}, _('Incompatible subscription nodes were skipped')),
            E(
              'ul',
              {},
              section.skippedSubscriptionOutbounds.map((item) =>
                E(
                  'li',
                  {},
                  `${item.tag}: ${
                    item.reason === 'unavailable-dependency'
                      ? _('Required connection is unavailable')
                      : _('Rejected by the selected core')
                  }`,
                ),
              ),
            ),
          ]),
        ]
      : []),
    E('div', { class: 'fkp_dashboard-page__outbound-grid' }, [
      ...metadataNodes,
      ...section.outbounds.map((outbound) => renderOutbound(outbound)),
    ]),
  ]);
}

export function renderSections(props: IRenderSectionsProps) {
  if (props.failed) {
    return renderFailedState();
  }

  if (props.loading) {
    return renderLoadingState();
  }

  return renderDefaultState(props);
}
