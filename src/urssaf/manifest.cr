# SPDX-License-Identifier: AGPL-3.0-or-later

# Manifeste de l'extension URSSAF (ADR-003 D2, ADR-007 D7).
#
# * Dépendance : `MICRO` (chiffre d'affaires par catégorie et par période,
#   « déclaration faite » du module).
# * Permissions : `urssaf.declaration.read` (voir les périodes, les
#   déclarations transmises et les cotisations dues),
#   `urssaf.declaration.transmit` (estimer et déclarer),
#   `urssaf.settings.manage` (identifiants de l'API, mandat).
# * Menus : « Déclaration URSSAF en ligne » sous « Éditions » (à côté de
#   l'écran URSSAF du module) et paramètres sous « Paramètres ».
Partiduo::Modules.register do
  code "URSSAF"
  name "urssaf.module.name"
  version "0.1.0"
  requires_core "~> 0.1"
  depends_on "MICRO"

  permission "urssaf.declaration.read"
  permission "urssaf.declaration.transmit"
  permission "urssaf.settings.manage"

  menu "URSSAF_ONLINE", parent: "REPORTS", order: 4, route: "urssaf:index", permission: "urssaf.declaration.read",
    label: "urssaf.menu.declarations"
  menu "URSSAF_SETTINGS", parent: "SETTINGS", order: 94, route: "urssaf:settings",
    permission: "urssaf.settings.manage", label: "urssaf.menu.settings"

  ui "bulma", path: "ui/bulma"
end
