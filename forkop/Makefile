include $(TOPDIR)/rules.mk

PKG_NAME:=forkop

FORKOP_SOURCE_VERSION:=$(or $(FORKOP_PACKAGE_VERSION),$(FORKOP_VERSION))
FORKOP_HAS_RELEASE_VERSION:=$(if $(filter dev,$(FORKOP_SOURCE_VERSION)),,$(FORKOP_SOURCE_VERSION))
FORKOP_COMPILED_VERSION:=$(if $(FORKOP_HAS_RELEASE_VERSION),$(FORKOP_SOURCE_VERSION),$(or $(FORKOP_SOURCE_VERSION),dev))
FORKOP_RELEASE_VERSION_VALID:=$(if $(FORKOP_HAS_RELEASE_VERSION),$(shell printf '%s\n' '$(FORKOP_SOURCE_VERSION)' | grep -Eq '^[0-9]+\.[0-9]+\.[0-9]+(-canary\.[0-9]+)?$$' && printf '1'),1)

ifeq ($(FORKOP_RELEASE_VERSION_VALID),)
$(error FORKOP_PACKAGE_VERSION and FORKOP_VERSION must use x.y.z or x.y.z-canary.N format)
endif

# apk-tools uses rc prerelease syntax; embedded/public version remains canary.N.
PKG_VERSION:=$(if $(CONFIG_USE_APK),$(subst -canary.,_rc,$(or $(FORKOP_HAS_RELEASE_VERSION),0.0.0)),$(or $(FORKOP_HAS_RELEASE_VERSION),0.0.0))
PKG_RELEASE:=

PKG_MAINTAINER:=Screamshow <235684779+Screamshow@users.noreply.github.com>
PKG_LICENSE:=GPL-2.0-or-later

include $(INCLUDE_DIR)/package.mk

define Package/forkop
	SECTION:=net
	CATEGORY:=Network
	DEPENDS:=+ca-bundle +kmod-inet-diag +kmod-tun +curl +ucode +ucode-mod-fs +ucode-mod-uci +kmod-nft-tproxy +bind-dig +nftables-json +kmod-nft-nat +ip-full
	CONFLICTS:=https-dns-proxy nextdns luci-app-passwall luci-app-passwall2
	TITLE:=Forkop backend service
	URL:=https://github.com/Screamshow/forkop-x
	PKGARCH:=all
endef

define Package/forkop/description
	Rule-based Forkop backend with sing-box orchestration
endef

define Build/Configure
endef

define Build/Compile
endef

define Package/forkop/prerm
#!/usr/bin/ucode

if (getenv("IPKG_INSTROOT") == null || getenv("IPKG_INSTROOT") == "") {
	let status = system("/usr/bin/forkop package_prerm " + (ARGV[0] || ""));
	exit(status > 255 ? int(status / 256) : status);
}

exit(0);
endef

define Package/forkop/postinst
#!/bin/sh

[ -n "$${IPKG_INSTROOT}" ] && exit 0
FORKOP_LIB=/usr/lib/forkop ucode -L /usr/lib/forkop /usr/lib/forkop/config/migration.uc migrate || exit $$?
/usr/share/forkop/mirror-migration.sh || exit $$?
/usr/bin/forkop package_postinst
endef

define Package/forkop/conffiles
/etc/config/forkop
endef

define Package/forkop/install
	$(INSTALL_DIR) $(1)/etc/init.d
	$(INSTALL_BIN) ./files/etc/init.d/forkop $(1)/etc/init.d/forkop
	$(INSTALL_BIN) ./files/etc/init.d/forkop-support $(1)/etc/init.d/forkop-support
	$(INSTALL_BIN) ./files/etc/init.d/forkop-tailscale $(1)/etc/init.d/forkop-tailscale
	$(INSTALL_BIN) ./files/etc/init.d/forkop-torrserver-direct $(1)/etc/init.d/forkop-torrserver-direct

	$(INSTALL_DIR) $(1)/etc/config
	$(INSTALL_CONF) ./files/etc/config/forkop $(1)/etc/config/forkop

	$(INSTALL_DIR) $(1)/usr/bin
	$(INSTALL_BIN) ./files/usr/bin/forkop $(1)/usr/bin/forkop

	$(INSTALL_DIR) $(1)/usr/lib/forkop
	$(CP) ./files/usr/lib/. $(1)/usr/lib/forkop/
	$(INSTALL_BIN) ./files/usr/lib/support/ssh-gate.sh $(1)/usr/lib/forkop/support/ssh-gate.sh
	$(INSTALL_BIN) ./files/usr/lib/tailscale/lan.sh $(1)/usr/lib/forkop/tailscale/lan.sh
	$(INSTALL_BIN) ./files/usr/lib/tailscale/transport.sh $(1)/usr/lib/forkop/tailscale/transport.sh

	$(INSTALL_DIR) $(1)/usr/share/forkop/defaults
	$(INSTALL_CONF) ./files/etc/config/forkop $(1)/usr/share/forkop/defaults/forkop
	$(INSTALL_BIN) ./files/usr/share/forkop/zapret-manager-upgrade.sh $(1)/usr/share/forkop/zapret-manager-upgrade.sh
	$(INSTALL_BIN) ./files/usr/share/forkop/zapret-manager-migrate.sh $(1)/usr/share/forkop/zapret-manager-migrate.sh
	$(INSTALL_BIN) ./files/usr/share/forkop/mirror-migration.sh $(1)/usr/share/forkop/mirror-migration.sh
	$(INSTALL_BIN) ./files/usr/share/forkop/package-init $(1)/usr/share/forkop/package-init

	sed -i -e 's/__COMPILED_VERSION_VARIABLE__/$(FORKOP_COMPILED_VERSION)/g' $(1)/usr/lib/forkop/core/constants.uc
endef

$(eval $(call BuildPackage,forkop))
