# SPDX-License-Identifier: AGPL-3.0-or-later

# Point d'entrée du shard `partiduo-urssaf` : le métier de l'extension
# URSSAF (manifeste, mandat, déclarations, suivi, transport abstrait,
# contrat `Urssaf::Api`), sans interface. L'interface Bulma est dans
# `ui/bulma/`, requise à part par la distribution :
# `require "partiduo-urssaf/ui/bulma"`.
#
# La distribution ajoute ensuite `Urssaf::INSTALLED_APPS` à ses
# applications Marten, et `require "partiduo-urssaf/cli"` à sa ligne de
# commande (migrations).
require "partiduo"

require "./urssaf/app"
