# Erreurs

Chaque erreur que Cepheus renvoie ou lève, le message exact, d'où elle vient, ce qu'elle veut dire, et que faire. Un
message du tableau est le texte à l'intérieur du constructeur ; `message e` ajoute la sorte devant (`"invalid: "`,
`"conflict: "`...). Les messages sont en anglais, tels que les programmes les affichent. Dans les messages, `#E` est un
numéro de chose, `P` un numéro de propriété, `NAME` le nom d'une propriété, `V` une valeur telle que l'affiche
`Value.to_string` (un texte entre guillemets, un lien comme `#E`, `money 120000`, `date 1700000000000`), `T` un type
(`int`, `float`, `bool`, `text`, `date`, `money(2)`, `link`), et `SEG` le nom de fichier d'un segment.

```ocaml
open Cepheus

let () =
  let db = fork empty in
  let[@warning "-8"] (Ok [ email; age ]) = declare db [ prop ~unique:true "client/email" Ttext; prop "client/age" Tint ] in
  let ada = thing (Result.get_ok (write db [ Add (-1, email, Text "ada@example.com") ])) (-1) in
  let try_ ops = match write db ops with Ok r -> Printf.printf "ok, group %d\n" r.group | Error e -> print_endline (message e) in
  try_ [ Add (-1, email, Text "ada@example.com") ];
  try_ [ Add (ada, age, Text "forty") ];
  try_ [ Add (ada + 1, age, Int 40) ];
  try_ [ Expect (ada, age, None); Add (ada, age, Int 40) ];
  try_ [ Expect (ada, age, None); Add (ada, age, Int 41) ];
  try_ [ Add (ada, 99, Int 1) ]
```

```output
not unique: client/email "ada@example.com" is taken
invalid: "forty" is not a int (property client/age)
invalid: no thing #65537
ok, group 4
conflict: #65536 has a value for client/age (property 17)
invalid: no property 99
```

Une écriture qui échoue ne change rien : aucun numéro de groupe n'est utilisé, aucun numéro de chose n'est pris.

## `Conflict` : un `Expect` n'a pas tenu

Renvoyée par `write`. Le groupe a été vérifié contre l'état le plus récent et l'un de ses `Expect` était faux : un autre
groupe a changé le fait depuis la vue que le client a lue. **Que faire** : prendre une nouvelle vue, décider à
nouveau, écrire à nouveau (la boucle habituelle de l'optimistic concurrency, le contrôle de concurrence optimiste).

| message | quand |
|---|---|
| `#E has a value for N (property P)` | `Expect (E, P, None)`, et E a une valeur pour P, dont le nom est N |
| `#E does not have V for N (property P)` | `Expect (E, P, Some V)`, et le fait (E, P, V) ne tient pas ; N est le nom de P |


Un changement des règles ou de l'ontologie (les faits qui décrivent les classes et les propriétés, que lisent les
règles) calculé en arrière-plan ([règles](rules.md#les-changements-des-règles-en-arrière-plan)) répond `Conflict` quand un
groupe écrit entre-temps a interféré ; `define` réessaie de lui-même :

| message | quand |
|---|---|
| `group G, written meanwhile, changed [#E P V], which the change writes` | le groupe a affirmé ou retiré un fait que le changement affirme ou retire |
| `group G, written meanwhile, changed the rules` | un changement fait dans son propre groupe (un changement qui crée de nouvelles choses) a été rangé avant |
| `#E would have two values of NAME under the new rules` | les groupes écrits entre-temps et les nouvelles règles donnent deux valeurs à une propriété qui n'en prend qu'une |
| `NAME V would be taken twice under the new rules` | la même chose pour une propriété unique |
| `constraint R: FACTS`, le refus d'une règle | les groupes écrits entre-temps enfreignent les nouvelles règles |
| `the change derived more than N facts with the groups written meanwhile` | les groupes écrits entre-temps ont fait dépasser son budget au changement |
| `the facts of the change were written meanwhile` | la partie affirmée du changement a changé entre sa construction et son installation |

## `Not_unique`

| message | quand | que faire |
|---|---|---|
| `NAME V is taken` | après le groupe, une autre chose a la valeur V pour la propriété unique NAME | choisir une autre valeur, ou la retirer de l'autre chose dans le même groupe |

## `Invalid` : la requête est fausse

Rien n'a été écrit. **Que faire** : corriger la requête ; réessayer sans rien changer donne la même erreur.

Depuis `write` (les vérifications du writer, les mêmes sur une base et sur un fork) :

| message | quand |
|---|---|
| `no property P` | P n'est pas une propriété déclarée de la vue |
| `Expect on a new thing` | un `Expect` nomme une chose négative (nouvelle) : elle n'a aucun fait avant le groupe |
| `Expect: V is not a T` | la valeur d'un `Expect` n'est pas du type de la propriété |
| `V is not a T (property NAME)` | un `Add` ou un `Retract` avec une valeur du mauvais type |
| `Incr counts on a one-valued int property of the program's: NAME is X` | un `Incr` d'un compteur qui n'est pas un `Int` (X : `a text`, ...), qui a plusieurs valeurs, ou qui est une propriété de la base elle-même (pas du programme) |
| `Incr writes into an int property of the program's: NAME is X` | un `Incr` dont le `into` n'est pas un `Int`, ou est une propriété de la base elle-même |
| `Incr: NAME of #E is N, and BY more passes the ints` | la somme du compteur dépasserait les 63 bits d'un int : le groupe est refusé, le compteur reste à N |
| `no thing #E` | E vaut 65 536 ou plus et la base ne l'a jamais créée |
| `no thing #E to link to` | un `Link` vers un numéro sous 16, ou vers une chose jamais créée |
| `#E is a system thing` | E est sous 16 : ces numéros sont réservés |
| `a property thing takes only cepheus/ properties` | une propriété ordinaire écrite sur une chose propriété (16 à 65 535) |
| `cepheus/ properties describe property things only` | `cepheus/name`, `type`, `many` ou `unique` écrit sur une chose ordinaire |
| `property P needs both a name and a type` | un groupe a laissé la chose propriété P avec un nom et pas de type, ou l'inverse |
| `property P keeps cepheus/many or cepheus/unique without a name and a type` | un groupe a laissé la chose propriété P avec `cepheus/many` ou `cepheus/unique` mais ni nom ni type |
| `property P has an unknown type code C` | `cepheus/type` tient un code qu'aucun type n'a (`Tmoney` avec plus de 18 chiffres) |
| `the type and the cardinality of NAME never change` | un groupe a changé le type ou le drapeau `many` d'une propriété ; déclarez une autre propriété |
| `NAME cannot become unique: two things share a value` | `cepheus/unique` mis à true alors que deux choses partagent une valeur |
| `NAME still has values` | le nom et le type d'une propriété retirés alors que des choses ont encore des valeurs pour elle |
| `a group of N bytes is over the frame limit of 268435456` | le codage du groupe dépasse 256 MiB, le plus grand corps de frame : découpez-le ([limites](limits.md#les-écritures)) |
| `thing numbers end at 2147483647: this group would make #N` | les nouvelles choses du groupe prendraient des numéros de chose au-delà de $2^{31} - 1$, le plus grand que tient un run ([limites](limits.md#choses-propriétés-valeurs)) ; la base ne peut plus créer de choses |

Depuis `write`, les liens qui nomment un kind et `Delete` ([api](api.md#les-liens-qui-nomment-un-kind--les-foreign-keys)) :

| message | quand |
|---|---|
| `NAME links to K things only, and #T is not one` | le groupe ajoute un lien de NAME (une propriété qui nomme le kind K) vers une chose qui n'a aucun fait de K après le groupe ; donnez à la chose un fait de K dans le même groupe, ou pointez vers une qui en a |
| `the K #X cannot be deleted while the L #Y links to it (NAME: refuse)` | le groupe laisse X sans fait de K (un `Delete`, ou le retrait de son dernier fait de K) alors que Y, du kind L, pointe encore vers elle par NAME, dont les liens le refusent ; supprimez ou reliez Y d'abord, dans ce groupe ou avant |
| `deleting the K #X (NAME: cascade): the links followed passed N facts, the work budget of a group of M operations: delete the things that link to it first, in groups of their own` | un `Delete` et les liens qu'il suit lisent ou retirent plus de $N = 10 \times (\mathit{base} + \mathit{per} \times M)$ faits (`work_budget`, `rule_budget`) ; rien n'est fait |
| `Delete of a new thing`; `Delete: no thing #E`; `Delete: the kind K has no property in this database` | un `Delete` d'une chose négative (nouvelle), d'une chose jamais créée, ou d'un kind qu'aucune propriété de la vue n'a |
| `NAME is a T: cepheus/to is for a link` | `cepheus/to` sur une propriété qui n'est pas un lien |
| `NAME: cepheus/to is the name of a kind, without '/', not "S"`; `NAME: cepheus/delete is refuse, cascade or clear, not "S"`; `NAME has cepheus/delete without cepheus/to, the kind it links to` | les deux faits d'un lien mal écrits (à la main : `link_to` les écrit bien) |
| `property P keeps cepheus/to or cepheus/delete without a name and a type` | un groupe a laissé la chose propriété P avec l'un d'eux mais ni nom ni type |
| `NAME links to the kind K, which has no property` | un lien nomme un kind qu'aucune propriété de la base n'a (un nom mal tapé) |
| `NAME cannot link to K things only: #E links to #T, which is not one` | un lien qui nomme un kind pour la première fois (ou un autre) alors qu'une valeur qu'il tient n'est pas une chose du kind |
| `rule R gives NAME, a link that names a kind: no rule gives one` | `define` d'une règle dont la tête est un tel lien, un lien qui reçoit ce nom alors qu'une règle le donne, ou une règle sur une propriété variable qui en donnerait un |
| `a group written meanwhile links NAME of #E to #T, which is no K thing under the change`; `a group written meanwhile leaves #Y linked by NAME to #X, which is no K thing any more` | (comme `Conflict`) un changement des règles en arrière-plan dont le groupe a déclaré un lien, pendant que des groupes écrits entre-temps le cassaient : refaites le changement |

Depuis `write` avec des règles (le raisonnement du writer, le même sur une base et sur un fork ; [règles](rules.md)) :

| message | quand |
|---|---|
| `[#E P V] is derived by rule R from F and G: retract one of those` | un `Retract` d'un fait qui n'est que dérivé : ses prémisses le dériveraient à nouveau ; retirez les faits affirmés qu'il nomme (les faits d'une preuve) |
| `[#E P V] is derived by a rule` | la même chose, quand aucune preuve n'a pu en être affichée |
| `rule R derived more than N facts from a group of K facts` | les changements dérivés du groupe dépassent le budget, $N = \mathit{base} + \mathit{per} \times K$ ([api](api.md#règles), `rule_budget`) ; R est celle qui a le plus dérivé. Découpez l'écriture, ou relevez le budget |
| `rule R derived more than N facts from a change of the rules or the ontology` | les faits dérivés d'un changement dépassent son budget, $N = \mathit{base} + \mathit{per} \times K + 4 \times$ les faits de la base (`change_budget`) ; R est celle qui a le plus dérivé |
| `a change of the rules or the ontology derived more than N facts` | la même chose, trouvée à l'installation du changement, après les groupes qu'il a rattrapés |
| `rule R read more than N candidates of its patterns for a group of K facts` | les candidats que lisent les règles du groupe (chaque fait qu'énumère un pattern d'un corps, d'un Not ou d'une contrainte) dépassent le budget de travail, $N = 10 \times (\mathit{base} + \mathit{per} \times K)$ (`work_budget`) ; R est celle qui a lu le dernier. Un corps dont les patterns partagent une valeur parcourt leur produit (trois choses d'un même tag : $n^3$). Joignez d'abord sur un pattern plus sélectif, découpez l'écriture, ou relevez le budget |
| `rule R read more than N candidates of its patterns for a change of the rules or the ontology` | la même chose pour un changement, $N = 10 \times$ son budget de faits dérivés |
| `the change failed: E` | un changement en arrière-plan a rencontré une erreur du moteur (un bug), écrite aussi sur la sortie d'erreur standard |
| `constraint R: FACTS` | le groupe rendrait vrai le corps de la contrainte R : FACTS sont les faits d'une instance |
| `rule R gives #E a second value of NAME, which takes one` | une valeur dérivée d'une propriété à une seule valeur à côté d'une autre valeur |
| `rule R gives NAME V, which another thing has` | une valeur dérivée d'une propriété unique qu'une autre chose tient |
| `rule R gives a fact about #E, which does not exist` | une tête nomme une chose que la base n'a jamais créée |
| `rule R gives a fact of #P, which is not a property it can give` | une tête dont la propriété est une variable donne une chose qui n'est pas une propriété de l'application (aucune, ou une propriété `cepheus/`) |
| `rule R gives NAME a value of another type` | une tête donne une valeur lue sous une propriété variable à une propriété d'un autre type |
| `rule R gives a fact about a value that is not a thing` | la chose d'une tête est une variable lue sous une propriété variable dont les valeurs ne sont pas des liens |

Depuis `define`, ou une écriture des faits d'une règle (une règle est vérifiée quand elle est écrite) :

| message | quand |
|---|---|
| `NAME is the name of a property` | `define` avec une règle nommée comme une propriété |
| `rule NAME: its body has no pattern` | `where` est vide |
| `rule NAME: N variables (at most 64)` | `vars` au-dessus de 64 |
| `rule NAME: variable ?K out of range` | un pattern ou la tête utilise K hors de 0 à `vars - 1` |
| `rule NAME: variable ?K appears in no pattern of the body` | une variable sous `vars` qu'aucun pattern du corps n'utilise |
| `rule NAME: the thing of a pattern is a variable or a thing` | la chose d'un pattern est un `Val` |
| `rule NAME: the property ?K is bound by no pattern whose property is a constant` / `… the property ?K of its head …` | une propriété variable (`prop_var K`) qu'aucun pattern à propriété constante n'a pour chose ou pour valeur |
| `rule NAME: no property P` / `… no property P in its head` | un pattern ou la tête nomme une propriété qui n'existe pas |
| `rule NAME: variable X is both a T and a U` | comme pour une question |
| `rule NAME: a range needs an int, date or money variable` / `… the bounds of ?X are not of its type` | un intervalle sur un autre type, ou des bornes d'un autre type |
| `rule NAME: V is not a T` | une constante du mauvais type pour sa propriété |
| `rule NAME: its head gives a cepheus/ property` | une tête sur une propriété système |
| `rule NAME: ?K is not a thing` / `… the thing of its head is a variable or a thing` / `… its head's thing #T is not an ordinary thing` | la chose de la tête n'est ni une variable de lien ni une chose ordinaire |
| `rule NAME: ?K is a T, NAME takes a U` / `… NAME takes a T, not a thing` | la valeur de la tête ne convient pas à sa propriété |
| `rule NAME: cannot read its definition at character N` / `… its definition is not in canonical form` | un fait `cepheus/rule` écrit à la main qui n'est pas le texte canonique d'une règle (Rules.to_text) |
| `rule R takes a name and a definition only` / `rule R needs a name and a definition, and no type` | une chose règle avec `cepheus/many`, `cepheus/unique` ou `cepheus/type`, ou sans son nom |
| `NAME is a property: it never becomes a rule` / `a rule never becomes a property (NAME)` | une chose du schéma changée d'une sorte en l'autre |

Depuis `declare`, `link_to` et `snapshot` :

| message | quand |
|---|---|
| `NAME is declared already as another kind of property` | `declare` avec un nom qui existe avec un autre type, une autre cardinalité ou un autre drapeau unique |
| `NAME links to K things in this database, with on delete D, not to L things with E` | `link_to` (ou un kind donné à Connect) d'une propriété qui nomme déjà un autre kind, ou un autre `on_delete` : les changer est une migration |
| `no property P` | `link_to` d'une propriété qui n'existe pas |
| `a fork has no files` | `snapshot` sur un fork |

Depuis `find` et `fold` (la question est mal formée) :

| message | quand |
|---|---|
| `no property P` | un pattern nomme une propriété qui n'existe pas |
| `variable X out of range` | un pattern utilise la variable X hors de 0 à `vars - 1` |
| `variable X is both a T and a U` | X apparaît avec deux propriétés de types différents (une place de chose est un `link`) |
| `variable X appears in no pattern` | une variable sous `vars` qu'aucun pattern n'utilise |
| `V is not a T` | une valeur constante du mauvais type pour sa propriété |
| `a range needs an int, float, date or money variable` | un intervalle sur une variable texte, ou sur une variable hors de 0 à `vars - 1` (les intervalles acceptent aussi les variables bool et link) |
| `a range of a float variable has float bounds, not V and W` | un intervalle sur une variable float dont les bornes ne sont pas des floats |

De `ask`, à côté de ceux-là (`Less`, `Less_or_equal`, `Optional`) :

| message | quand |
|---|---|
| `Less compares two variables of one type, not a T and a U`; `Less compares ints, floats, dates, money, texts and links, not bools` | `Less` ou `Less_or_equal` entre deux types, ou sur des bools |
| `variable N of a condition appears in no pattern` | une variable de `Less` (ou d'un intervalle, de `In`, de `Prefix`) qu'aucun pattern ne lie |
| `the thing of Optional is a variable that a pattern of the question binds, or a thing's id` | un `Optional` dont la chose est une valeur, ou une variable qu'aucun pattern ne lie (la valeur d'un autre `Optional` comprise) |
| `the value of Optional is a variable`; `the value of Optional is a variable in no other item of the question: variable N is in M` | un `Optional` dont la valeur est une constante, ou une variable qu'un autre élément utilise |
| `the value of Optional is one of the question's first 62 variables, not N`; `a question with Optional gives at most 62 columns, not N` | les bits d'un `int` tiennent les cellules absentes |
| `Not takes patterns and conditions: no Not, Or or Optional inside it`; `an alternative of Or takes patterns and conditions: no Not, Or or Optional inside it` | un `Optional` (ou un `Not`, un `Or`) dans un `Not` ou une alternative |
| `Sum, Min and Max take a variable of a pattern, not an Optional's, which may be missing: give its values, or Count the rows` | un agrégat de la variable d'un `Optional` (`Count` compte ses lignes) |

De `ask` et d'un rapport (`Trunc`, et les agrégats du protocole 9 par le serveur et Cesia) :

| message | quand |
|---|---|
| `"N" is not a time zone name: an IANA name, as "Europe/Paris", or "UTC"` ; `no time zone N in the zone database (DIR): ...` | un nom de fuseau avec un caractère autre que des lettres, des chiffres, `_`, `-`, `+` et `/`, une partie vide, `.` ou `..` (aucun autre fichier n'est lu), ou un nom que la base des fuseaux du système ne tient pas |
| `the time zone N counts leap seconds: ...` ; `the time zone N: its file ...` | un fuseau de `right/` (ses secondes ne sont pas celles d'UTC), ou un fichier qui n'est pas un fichier TZif ou ne se lit pas |
| `Trunc takes a unit of second, minute, hour, day, week, month, quarter, year, decade, century, millennium, not "U"` | une autre unité |
| `Trunc takes a date, not a T` ; `Trunc takes a date variable of a pattern of the question, not variable N` ; `Trunc gives variable N, not M: its variables come after the question's ...` | un `Trunc` d'un autre type, d'aucune variable de la question, ou numéroté hors de sa place (le i-ième `Trunc` donne la variable `vars + i`) |
| `Trunc is for Give: its variable is computed as a row is given` ; `Not takes patterns and conditions: no Not, Or or Optional inside it` | un `Trunc` là où est une condition (c'est une colonne) |
| `Avg is for ints, floats, money and dates, not a T` ; `Variance is for ints, floats and money, not a T` (et `Stddev`) ; `Quantile between two values is for ints, floats, money and dates, not a T: Quantile(x, p, discrete = true) takes one of the values` | un agrégat d'un type qu'il ne prend pas |
| `Quantile's fraction is from 0 to 1, not P` | un quantile sous 0, au-dessus de 1, ou NaN |
| `Avg takes a variable of a pattern, not an Optional's, which may be missing: ...` (et `Quantile`, `Variance`, `Stddev`) | un agrégat de la variable d'un `Optional` (`Count(x)` et `Values` laissent de côté ses valeurs absentes) |
| `Sort's keys are not a Values column: it is a list` | un champ `Values` comme clé de `Sort` |
| `Sum of NAME passed the 63 bits of an Int in the group K: group by a finer key, or ask its Avg and Count (exact)` ; `Sum of NAME passed the 63 bits of an Int: group by a key, or ask its Avg and Count (exact)` | une `Sum` d'ints ou de money (NAME : la propriété dont sa variable est la valeur) dont le total exact dans un groupe est au-delà de $\pm 2^{62}$ ; K : les valeurs des clés du groupe, le premier tel groupe dans l'ordre des clés du moteur, coupées à 64 caractères ; le second message : un rapport d'un seul groupe, sans clé. La question est refusée quels que soient son `Sort`, son `Limit` et son `After` (l'ordre peut suivre cette somme) ; un total qui passe $2^{62}$ en chemin et y revient est donné, le même sur n'importe quel nombre de cœurs. Un watch de cette somme finit avec cette erreur au frame qui la fait passer au-delà, les autres watches continuant ([les limites](limits.md#les-questions)) |
| `Trunc of NAME to the UNIT of date D: its unit starts before the least date, -2^62 ms (146 million years before 1970)` | un `Trunc` d'une date parmi les plus petites (D ses millisecondes) dont l'unité commence avant $-2^{62}$ ms, la plus petite date : aucune date ne tient ce début. Un watch finit avec cette erreur au frame qui apporte la date, les autres watches continuant |

D'un select avec des fenêtres ou `Each` (le protocole 10 : `Wire.Over`, les `Running`, `Rank`, `Prev` et `Each` du
package Cesia) :

| message | quand |
|---|---|
| `Running needs Sort: a window reads the rows in an order` (et `Rank`, `Prev`) ; `Each needs Sort: the first rows of each group, or its windows, are in an order` | une fenêtre ou `Each` sans `Sort` |
| `Each is for Limit or a window (Running, Rank, Prev): this question has neither` | un `Each` qui ne changerait rien |
| `Each takes no After: with Each, Limit is each group's, so a page has no last row to go on from; ask a page of the groups, then their rows (In)` | `Each` avec `After` |
| `Each takes the keys of a report, not its aggregates: column N` ; `Each: column N twice` ; `Each: column N out of range` | `Each` d'un agrégat, d'un même champ deux fois, ou d'aucune colonne |
| `Running's Sum is of ints and money, not a T` ; `Running's Avg is of ints, floats, money and dates, not a T` ; `Running's Min is of ints, money and dates, not a T` (et `Max`) | un agrégat de fenêtre d'un type que l'agrégat ne prend pas |
| `Running takes Sum, Avg, Min or Max of a column, or Count(), not A` | `Running` de `Count(x)`, de `Values`, d'un quantile, d'une variance |
| `Running's last is 1 to 100000 rows (0: from the first row), not N` ; `Prev goes back 1 to 100000 rows, not N` ; `Rank ranks by 1 to K keys of Sort, not N` | un frame, un `Prev` ou un `Rank` hors de ses bornes |
| `Running: column N out of range` (et `Prev`) ; `Running takes no Values column: it is a list` | une fenêtre d'aucune colonne, ou d'une liste |
| `windows and Each are not for a report with Values: a group is then several rows, one a value` ; `windows over windows: Over takes a Give or a Group` | une fenêtre sur un rapport avec `Values`, ou sur des fenêtres |
| `Running's Sum of C passed the 63 bits of an Int: sum fewer rows (last = n)` | une somme cumulée au-delà de $\pm 2^{62}$ dans une ligne que la réponse donne ; C la colonne qu'elle somme : la propriété d'un champ (`invoice/total`), ou un agrégat d'un rapport (`Sum(invoice/total)`) |
| `at most 64 windows, not N` | plus de fenêtres qu'une question n'a de variables |

### Les templates et l'égalité

| message | quand |
|---|---|
| `rule R: one every [..] a rule`; `rule R: the member ?k of every [..] is in no other pattern`; `… is in its head …`; `rule R: a template (every) takes no Not and no aggregate` | un template (une règle dont un pattern se répète pour chaque membre d'une liste) mal écrit |
| `rule R gives P, the list of the template T: only a write may change a list` | la tête d'une règle est la liste d'un template, ou une règle a dérivé un fait d'une telle liste |
| `rule R: the list of #c has N members (a template takes at most 64)` | une écriture rend une liste trop longue pour son template |
| `rule R makes two different values the same: only things can be the same as another` | une égalité entre deux valeurs qui diffèrent (prp-fp, la règle d'OWL 2 RL pour une propriété qui n'a qu'une valeur par chose, sur une propriété de textes avec deux valeurs) |
| `rule R would make the property #p the same as another thing: a property is the same as no other` | une égalité sur une chose qui est une propriété |
| `rule R would make #a the same as #b, which a rule names: a thing the rules name keeps its own identity` | une égalité sur une constante des règles (owl:Thing, la classe de toutes les choses ; une classe que nomme une règle dépliée, c'est-à-dire réécrite pour chaque fait d'une petite relation) |
| `rule R: a rule that makes things the same takes no Not and no aggregate`; `a rule set that makes things the same takes no Not and no aggregate yet` | l'égalité à côté de la négation ou des agrégats |
| `rule R: cepheus/same is read through the classes of equal things, not by a rule's pattern` | le corps d'une règle lit `cepheus/same` |
| `constraint owl/eq-diff1: [#r owl/DifferentFrom #r]` | deux choses déclarées différentes sont rendues égales |

## `Damaged` : des données durables perdues ou changées

Les fichiers ne tiennent plus ce que la base a rendu durable : un disque qui a changé des octets, un fichier mal copié,
un segment supprimé à la main. La base **refuse de s'ouvrir** plutôt que de laisser tomber un groupe confirmé en
silence (G6). **Que faire** : ne supprimez ni ne modifiez aucun fichier ; lancez `cepheus verify DIR` pour chaque
défaut (il ne change rien) ; restaurez depuis une sauvegarde (`cepheus restore BACKUP DIR --replace`, qui garde de côté
le dossier endommagé). Ne coupez un journal à
la main que si vous savez que la frame endommagée n'a jamais été confirmée
([opérations](operations.md#quand-la-recovery-dit-damaged)).

Depuis `open_` (la recovery, la remise en état à l'ouverture) et `verify` ; `SEG` est le nom du segment, un offset est
en octets depuis le début du segment :

| message | ce qu'il veut dire |
|---|---|
| `DIR/cepheus is not a Cepheus database file` | le fichier d'identifiant de la base ne fait pas 37 octets, ou son nombre magique ou son CRC est faux |
| `SEG: unknown format F` | un en-tête de segment qui se vérifie mais a un format autre que 2, celui du journal (un segment de format 1 est converti à l'ouverture) |
| `SEG: a segment of another database` | l'identifiant de base du segment n'est pas celui de cette base (fichiers de deux bases mélangés) |
| `journal: segment SEG, where the snapshot starts, is missing` | le run le plus récent reprend dans un segment qui n'est pas là |
| `journal: the first segment starts at group G` | aucun run, et le segment le plus ancien ne commence pas au groupe 1 |
| `journal: SEG does not follow group G (a segment is missing)` | un trou entre deux segments |
| `journal: SEG has a broken header` | un segment autre que le plus récent a un en-tête qui ne se vérifie pas |
| `journal: SEG has a broken header, with N bytes after it` | le segment le plus récent tient des octets après son en-tête, qui ne se vérifie pas : l'en-tête a été forcé (écrit jusqu'au disque) avant toute frame, donc il a changé depuis (G6) |
| `journal: SEG, where the newest run starts, has a broken header` | le run le plus récent reprend dans un segment dont l'en-tête ne se vérifie pas, ou qui est plus court que son en-tête : le writer avait forcé cet en-tête |
| `journal: SEG says it starts at group G` | l'en-tête d'un segment et son nom de fichier ne sont pas d'accord |
| `journal: SEG is shorter than the snapshot says` | le run le plus récent reprend au-delà de la fin du segment |
| `SEG: frame at O starts at group G, expected N` | une frame qui se vérifie, hors de la séquence |
| `SEG: group G where N was expected` | un groupe hors de la séquence à l'intérieur d'une frame |
| `SEG: frame at O does not decode` | une frame qui se vérifie mais dont les groupes ne peuvent pas être lus |
| `SEG: frame at O has bytes after its groups` | la même chose |
| `SEG: damaged frame at offset O (written whole)` | la frame ne se vérifie pas, et un en-tête de frame plus loin se vérifie ou son trailer correspond à son corps : autrefois durable, maintenant endommagée |
| `SEG: segment ends with a broken frame at O` | une frame qui ne se vérifie pas à la fin d'un segment qui n'est pas le plus récent (les segments sont forcés en entier avant que le suivant commence) |
| `the journal ends at group G, before the snapshot of group S` | le run le plus récent tient des groupes que le journal a perdus (un run n'est nommé qu'une fois ses groupes durables) |
| `group N uses property P, which does not exist` | le replay a rencontré un changement d'une propriété qu'aucun groupe n'a déclarée |

Au démarrage d'un serveur, depuis son commit buffer (l'endroit où le serveur copie les frames de plusieurs bases pour
les confirmer par un seul fsync : [le serveur](server.md#plusieurs-bases-un-seul-fsync--le-commit-buffer) ; `FILE` est
`DATA/server.wal.1` ou `.2`) :

| message | ce qu'il veut dire |
|---|---|
| `FILE: a broken header` | un fichier du buffer dont l'en-tête ne passe pas la vérification (un fichier ne prend son nom qu'une fois son en-tête durable) |
| `FILE: unknown format F` | un en-tête qui passe la vérification, d'un autre format que 1 |
| `server.wal.N: damaged round at offset O (written whole)` | un round (une tournée du buffer : une écriture confirmée par un fsync) qui ne passe pas la vérification, dans le fichier le plus ancien, ou suivi d'un round écrit en entier : il a été durable, il est maintenant endommagé |
| `FILE: round R at O does not hold its entries` / `has bytes after its entries` | un round qui passe la vérification mais dont les entrées ne font pas exactement son corps |
| `server.wal.1 holds confirmed writes of databases this server did not open (ids ...): open them with it once` | le buffer contient des frames d'une base que `cluster.toml` ne liste plus : la rajouter, démarrer le serveur, l'arrêter ([opérations](operations.md#une-base-dun-serveur)) |
| `journal: segment SEG, where the commit buffer's frames go, is missing` | le run le plus récent reprend dans un segment qui n'est pas là |
| `SEG: the frame at O (group G) does not check, before the commit buffer's frames from group N` | une frame que le buffer ne contient pas, avant des frames qu'il contient : elle a été forcée, et elle est endommagée |
| `journal: the commit buffer's frame of group G does not start where a frame does (group N)` | les frames du journal et celles du buffer ne s'alignent pas |
| `SEG: the frame at O is not the one the commit buffer holds for group G (the database was written without its server's buffer after a crash)` | une autre frame qui passe la vérification est là où va celle du buffer : une version sans le buffer a ouvert la base après un crash et y a écrit ; elle n'est jamais écrasée ([opérations](operations.md#une-base-dun-serveur)) |

Depuis `verify` seulement (une lecture complète est stricte : la recovery répare ceux-ci, donc après elle ce sont des
dommages) :

| message | ce qu'il veut dire |
|---|---|
| `journal: the newest segment has a broken header` | un segment le plus récent pas plus long que son en-tête, torn (écrit en partie seulement) à sa création, jamais réparé par une recovery |
| `SEG: the trailer of the frame at O is damaged` | une frame dont l'en-tête et le corps se vérifient, mais pas son trailer |
| `SEG: the frame at O does not check` | la frame la plus récente ne se vérifie pas (une fin torn, ou un dommage de la frame la plus récente : le cas résiduel de G6) |

Depuis les lectures des runs (`find`, `fold`, `write` et `snapshot` renvoient `Damaged` ; `get`, `values`, `things` et
le `write` d'un fork lèvent `Unreadable` avec le même message) :

| message | ce qu'il veut dire | que faire |
|---|---|---|
| `run NAME: page K does not check` | la page K (16 KiB) du fichier d'un run a été lue sur le disque et son CRC-32C ne correspond pas : jamais servie | le run est endommagé (c'est un cache : le journal est intact). Fermez la base et ouvrez-la à nouveau : un run qui tient dans le cache est vérifié en entier à l'ouverture et mis de côté. Un plus grand n'est pas lu en entier à l'ouverture : sortez son fichier de `snapshots/` (gardez-le pour le diagnostic) et ouvrez à nouveau ; les autres runs et le journal reconstruisent l'état |
| un message de `Disk.Io` (plus bas) | le disque n'a pas pu lire la page | comme pour `Io` |

Les **runs mis de côté à l'ouverture** ne sont pas des erreurs : l'ouverture choisit une autre chaîne de runs sans lui,
ou rejoue le journal, et `notes db` liste `snapshot NAME set aside: REASON`, où REASON est l'un de `shorter than its
header`, `not a run`, `its header does not check`, `unknown format F`, `a run of another database`, `its groups are not
those of its name`, `bad counts`, `its journal position is after its group`, `shorter than its header says`, `its
checksum table does not check`, `its layout does not match its size`, `the rank table of its additions is out of
order`, `the rank table of its additions does not end at N` (et la même chose pour `its retractions`), `the thing
offsets of its additions is out of order`, `the property offsets of its retractions does not end at N` (chaque table de
chaque partie), `the text offsets is out of order`, une erreur de schéma du tableau ci-dessus, une page qui ne se
vérifie pas, ou un message de `Disk.Io`. Un snapshot d'un format plus ancien (`<group>.snap`, format 4 et avant) donne
`snapshot NAME set aside: an earlier format, the journal is replayed` : l'ouverture rejoue tout le journal une fois, et
le premier merge supprime l'ancien fichier.

## `Io` : le disque a lâché

Un appel système a échoué. Pendant une écriture ou un fsync du journal (fsync : l'appel système qui attend que les
octets écrits soient vraiment sur le disque), la base **s'arrête** (G10) : ce groupe et chaque groupe suivant renvoient
un `Io`, `snapshot` aussi ; elle ne retente jamais le fsync, parce qu'après un fsync qui échoue le noyau a marqué clean
(identiques au disque) les pages qu'il n'a pas pu écrire, et un second fsync réussirait sans les écrire (Rebello et al.
2020). Le writer ramène aussitôt le journal à sa dernière frame durable, si bien que les écritures qui ont échoué sont
absentes (G13). **Que faire** : réparez le disque (place, permissions, matériel), fermez la base avec `close` et
ouvrez-la à nouveau : la recovery repart du journal, après avoir écrit à nouveau sa frame la plus récente (aucun
redémarrage de la machine n'est nécessaire). Un merge qui échoue n'arrête pas la base (plus bas) ; un grand groupe dont
le fichier de run échoue renvoie `Io` pour ce seul groupe. Le message est `CALL PATH: REASON`, où CALL est l'un de
`open`, `read`, `write`, `lseek`, `fstat`,
`ftruncate`, `fsync`, `close`, `rename`, `unlink`, `mkdir`, `readdir`, `lock`, et REASON le texte du système (`No space
left on device`) ; ou bien `read PATH: short file` (un fichier plus court que ne le dit son en-tête), `file N is
closed`, `journal is closed`, et `journal: an earlier write failed; reopen the database` (les écritures après le
premier échec).

## `Busy` et `Closed`

| erreur | message | quand | que faire |
|---|---|---|---|
| `Busy` | `DIR is open in another process` | un autre processus tient `DIR/lock`, ou ce processus a déjà la base ouverte, sous ce chemin ou n'importe quel autre qui nomme le même répertoire (un lien symbolique, `DIR/.`, `x/../DIR`) | fermer l'autre ; un seul moteur par base |
| `Busy` | `DIR was written through a server's commit buffer and not closed cleanly: its newest writes may be in the server's DATA/server.wal.1 or .2 alone; start the server on its data directory, which writes them into the journal, and stop it` | `open_` dans le processus même d'un programme, d'une base que tenait un serveur quand il a crashé (`DIR/shared` et pas de `DIR/closed`) | démarrer le serveur et l'arrêter ; la base s'ouvre ensuite n'importe où ([opérations](operations.md#une-base-dun-serveur)) |
| `Closed` | `the database is closed` | `write` ou `snapshot` après `close` | ouvrir la base à nouveau |

## `Timeout` : une question a dépassé son temps

| erreur | message | quand | que faire |
|---|---|---|---|
| `Timeout` | `the question took more than N s, its time: ask a narrower one, or give it more time` | `find`, `ask` ou `fold` avec `~timeout:N` a dépassé N secondes (regardé tous les 1 024 candidats de chaque domain : elle finit à quelques millisecondes de son temps) ; rien n'en est rendu ([limites](limits.md#les-questions)) | une question plus étroite (un pattern sélectif d'abord, un intervalle, des pages avec Sort et Limit), ou plus de temps |

`find`, `ask` et `fold` lèvent `Invalid_argument` pour un timeout de 0 ou moins, ou NaN : une erreur du programme.

## Exceptions

| exception | levée par | quand |
|---|---|---|
| `Unreadable of string` | `get`, `values`, `things`, le `write` d'un fork | une page d'un run ne peut pas être lue ou ne se vérifie pas (plus haut) |
| `Not_found` | `thing r k` | k n'est pas une nouvelle chose du groupe du reçu r |
| `Failure "Cepheus needs the processor's CRC-32C instruction (SSE4.2 on x86-64, CRC32 on arm64), and this processor has none"` | le démarrage du programme, avant que son propre code tourne (l'initialisation de `Crc32c`) | le processeur n'a pas l'instruction qu'utilise chaque checksum ([limites](limits.md#les-fichiers-et-la-plateforme)) : un x86-64 plus ancien que le niveau x86-64-v2, ou un arm64 ARMv8.0 sans les instructions CRC32 optionnelles. Lancez-le sur une autre machine ; rien n'a été lu ni écrit |
| `Failure "bootstrap: ..."` | `open_` d'une nouvelle base | le premier groupe, qui décrit les propriétés système, a été refusé : un bug |
| `Invalid_argument` | internals | un invariant cassé, ce qui est un bug : `Journal.append: groups out of order`, `Engine.install: not durable`, `Snapshot.merge: ...` (une section qui déborde ou dont les comptes ne tombent pas juste, un retrait sans rien en dessous, un fait d'un grand groupe au-delà des choses, la position du journal après la vue, plus de runs que n'en a la vue) ; `Pages: a page of a base built in memory is missing` ; ou un mauvais usage d'une fonction interne (`Codec.reader`, `Codec.put_varint` d'un nombre négatif, `Crc32c.bytes`, `Crc32c.extend`, `Rng.int`) ; `Journal.append: frame too large` (le writer ne fait jamais de frame au-delà de 256 MiB, c'est donc un bug) ; et `Cepheus.decode: variable X out of range` ou `Cepheus.decode: MSG` (une question que `fold` refuse), un mauvais usage de `decode` |

## À travers le serveur

Un programme connecté au serveur reçoit chaque erreur ci-dessus comme une valeur `{code, message}` (`conflict`,
`invalid`, `unique`, `damaged`, `io`, `busy`, `closed`, `timeout`), et les codes propres au serveur : `auth`, `denied`, `version`,
`too_large`, `unknown_database`, `stopping`, `refused`, `too_many_connections`, `idle`, `internal`, `read_only` (une
replica, une copie de la base tenue à jour sur une autre machine, qui ne prend pas d'écritures), et, dans un cluster
Raft (des serveurs qui gardent les mêmes bases et le même log, la liste ordonnée des écritures, par l'algorithme de
consensus Raft), `not_leader` (ce serveur suit un leader, le serveur du cluster qui reçoit les écritures : son message
le nomme, et son corps porte l'adresse du leader, que la bibliothèque OCaml suit d'elle-même) et `no_leader` (une
élection, le vote qui choisit un leader, est en cours, ou le nouveau leader n'est pas prêt : réessayer ; la
bibliothèque OCaml le fait, dans son budget de nouvelles tentatives). Chacun, quand il arrive et que faire :
[le serveur](server.md#erreurs).

Celles du vault de fichiers (là où Cepheus garde les octets des fichiers : [le vault](vault.md)), à travers le serveur
ou depuis `Cepheus_vault.Vault` :

| code | message | quand | que faire |
|---|---|---|---|
| `missing` | `thing T has no file of this kind`, `chunk H is not in the vault` | un Load d'une chose sans fichier ; un record (une entrée écrite par le vault) qu'un fait cite et que le vault ne contient pas (un vault copié sans ses packs, les fichiers où il ajoute ses records) | vérifier la chose ; restaurer les packs |
| `damaged` | `record H: its tag does not check (the bytes changed on the disk)`, `... its header does not check`, `... the record found there is another one`, `... its bytes do not match their CRC` | un chunk (un morceau d'un fichier) ou un nœud (une entrée de l'arbre qui relie les chunks d'un fichier) changé sur le disque | remettre le même fichier (le chunk endommagé est écrit de nouveau), ou restaurer depuis une copie |
| `erased` | `the files of domain D were erased (its key is destroyed)` | un Load d'un fichier d'un propriétaire effacé, ou un Put qui le nomme | rien : c'est définitif |
| `invalid` | `the master key does not open the key of domain D (another vault's key?)` | le vault ouvert avec une autre clé maîtresse que la sienne | donner au serveur son propre `vault.key` |
| `damaged` | `keys: the entry at N does not check, and later ones do` | le fichier des clés a changé sur le disque avant sa fin | restaurer `keys` depuis une copie (une clé perdue, ce sont les fichiers d'un domaine, ceux d'un propriétaire, perdus) |
| `busy` | `DIR is open in another process` | un second processus ouvre le même vault | un processus par vault |

## Dans un programme Cesia

Le client Cesia ([Cepheus depuis Cesia](cesia.md)) donne chaque erreur ci-dessus, et celles du serveur, comme une
valeur `result.Err({Kind: "cepheus", Code, Message})`, avec les codes en minuscules (`conflict`, `unique`, `invalid`,
`damaged`, `io`, `busy`, `closed`, et ceux du serveur), et ajoute les siennes :

| Code | Message | quand | que faire |
|---|---|---|---|
| `invalid` | `P needs a Text` (an Int, a number, a Bool, a date in seconds since 1970, an amount), `not V` | une valeur donnée pour la propriété P n'est pas de son type | donner une valeur du type de la propriété |
| `invalid` | `P needs an amount that fits` | une valeur Money au-delà de 63 bits une fois en unités mineures | un montant plus petit |
| `invalid` | `P needs a date in seconds since 1970, not V` | aussi une date de $4{,}6 \times 10^{15}$ s ou plus, dans un sens ou dans l'autre (ses millisecondes dépasseraient 63 bits) | une date dans l'intervalle |
| `invalid` | `the kind K has no field F` | un champ donné à Insert ou Update que le kind ne déclare pas | corriger le nom du champ (il n'est jamais laissé tomber en silence) |
| `invalid` | `P is not declared in this database: give its kind to Connect (or Fork)` | un kind utilisé sur une base à qui on ne l'a pas donné | ajouter le kind à la liste de Connect, ou de Fork |
| `invalid` | `P is a T in this database, not a U` | la base déclare la propriété avec un autre type | le kind doit correspondre au schéma de la base |
| `invalid` | `Insert needs at least one field of K`, `Update needs at least one field of K`, `Update needs the id of a thing, not N`, `a group needs at least one operation` | une écriture vide | écrire quelque chose |
| `invalid` | `P holds several values: change them with Write, Add and Retract` | un Update d'un champ à plusieurs valeurs | `cepheus.Write` avec `Add` et `Retract` |
| `invalid` | `Above, Below and Between are for ints, floats, dates, money and things, not a T`; `a variable of Above, Below or Between appears in no pattern` | un intervalle sur un autre type, ou sur une variable d'aucun pattern | filtrer les lignes en Cesia (`list.Filter`) |
| `invalid` | `Less compares two variables of one type, not a T and a U`; `Less compares ints, floats, dates, money, texts and links, not bools` | `Less` ou `LessOrEqual` entre deux types, ou sur des bools (une constante dedans est une erreur du programme, comme tout argument de la mauvaise sorte : l'erreur de Cesia elle-même) | comparer deux variables d'un même type ; une variable et une constante avec `Above` ou `Below` |
| `invalid` | `Optional is at the top of Where: no Optional inside Not or Or`; `the thing of Optional is a variable that a pattern of the question binds, or a thing's id`; `the value of Optional is a variable in no other item of the question: variable N is in M` | un `Optional` dans un `Not` ou un `Or`, sans pattern, d'une chose qu'aucun pattern ne lie, ou dont la variable sert à un autre élément ([Less et Optional](cesia.md#less-lessorequal-et-optional)) | lier sa chose par un pattern ; donner à sa valeur une variable à elle |
| `invalid` | `Sum, Min and Max take a variable of a pattern, not an Optional's, which may be missing: give its values, or Count the rows` | un agrégat de la variable d'un `Optional` | `Count()`, ou donner ses valeurs |
| `invalid` | `Sort's keys are fields of Give: a variable or an aggregate that Give gives` | une clé de Sort que Give ne donne pas | l'ajouter à Give (After est une ligne : elle contient chaque clé) |
| `invalid` | `After needs Sort: the rows after a row, in an order`; `After needs every field of Give: F is missing`; `After's N needs a T, not V` | un curseur sans ordre, ou qui n'est pas une ligne entière de Give | donner Sort, et une ligne d'une réponse précédente |
| `invalid` | `Not takes 1 to 4 patterns or conditions, not N`; `Or takes 2 to 4 alternatives, not N`; `And takes 1 to 4 patterns or conditions, not N`; `Not takes patterns and conditions: no Not or Or inside it`; `Or takes patterns, conditions and And: no Not or Or inside it`; `And is for an alternative of Or: Where is already all of its items` | la forme de Not, Or et And | nommer une condition plus profonde par une règle, comme un fait dérivé |
| `invalid` | `an Or of one pattern that differs only in its value is In's case: write In(x, [...]) on the pattern's variable` | un `Or` qui est un `In` | `cepheus.In` (une seule façon de l'écrire) |
| `invalid` | `variable N is in no pattern of the question: it may be the own of one Not or one Or only`; `variable N is a Not's or an Or's own: Give and Sort take the question's variables`; `a question needs a pattern outside Not` | une variable partagée par deux Not, donnée, ou une question faite de Not seulement | la lier par un pattern de la question |
| `invalid` | `In needs values of the variable's type (a T), not V`; `a variable of In appears in no pattern` | `In` avec des valeurs d'un autre type | des valeurs du type de la variable |
| `invalid` | `this server speaks protocol 1: Not, Or, In, Prefix, Sort, Limit and After need a server of protocol 2` | une question qui les utilise, sur une connexion à un serveur d'une version antérieure | mettre à jour le serveur ([mises à jour](production.md#les-mises-à-jour)) |
| `invalid` | `this server speaks protocol 3 or older: Incr needs a server of protocol 4` | un groupe avec `cepheus.Incr`, sur une connexion à un serveur d'une version antérieure : refusé avant d'être envoyé | mettre à jour le serveur ([mises à jour](production.md#les-mises-à-jour)) |
| `invalid` | `this server speaks protocol N: a question's timeout needs a server of protocol 6` | `Find` ou `Watch` avec `timeout`, sur une connexion à un serveur d'une version antérieure : refusé avant d'être envoyé | mettre à jour le serveur, ou laisser le temps au `question_timeout` du serveur |
| `invalid` | `this server speaks protocol N: Less, LessOrEqual and Optional need a server of protocol 7` | `Find` ou `Watch` avec eux, sur une connexion à un serveur d'une version plus ancienne : refusé avant d'être envoyé | mettre le serveur à jour ([les mises à jour](production.md#les-mises-à-jour)) |
| `invalid` | `this server speaks protocol N: Delete and links that name a kind need a server of protocol 8` | `Delete` d'une chose qui n'est pas un fichier, ou `Connect` avec un kind dont un `Link` a `to`, sur une connexion à un serveur d'une version plus ancienne : refusé avant d'être envoyé | mettre le serveur à jour ([les mises à jour](production.md#les-mises-à-jour)) |
| `invalid` | `this server speaks protocol N: Trunc, Avg, Count(x), Values, Quantile, Variance and Stddev need a server of protocol 9` | `Find` ou `Watch` avec un agrégat d'un rapport ou un `Trunc`, sur une connexion à un serveur d'une version plus ancienne : refusé avant d'être envoyé | mettre le serveur à jour ([les mises à jour](production.md#les-mises-à-jour)) |
| `invalid` | `this server speaks protocol N: Running, Rank, Prev and Each need a server of protocol 10` | `Find` avec des fenêtres ou `Each`, sur une connexion à un serveur d'une version plus ancienne : refusé avant d'être envoyé | mettre le serveur à jour ([les mises à jour](production.md#les-mises-à-jour)) |
| `invalid` | `Running's t takes a field of Give (a variable, an aggregate or a Trunc that Give gives): give it too, as Amount: t` (et `Prev`) ; `Each takes fields of Give: give the variable too, as Client: c` ; `Each takes the keys of the rows (a variable or a Trunc of Give), not an aggregate` ; `Sort's keys are not windows: a window's value is computed from the order` | une fenêtre d'une variable que `Give` ne donne pas (dans un rapport : `Running(Sum(t))` où la ligne est un groupe, `Running(Sum(Sum(t)))` le total cumulé de ses sommes), `Each` d'aucun champ ou d'un agrégat, une fenêtre comme clé de `Sort` ([les fenêtres](cesia.md#les-fenêtres--running-rank-prev-each)) | donner le champ ; dans un rapport, la fenêtre du champ de l'agrégat |
| `invalid` | `Running needs Sort: ...` ; `Each takes no After: ...` ; `Running's last is 1 to 100000 rows ...` ; `Running's Sum of C passed the 63 bits of an Int: ...` ; chaque message des fenêtres plus haut | une fenêtre ou un `Each` que le moteur refuse ([les fenêtres](cesia.md#les-fenêtres--running-rank-prev-each)) | comme le dit le message |
| `invalid` | `"N" is not a time zone name: ...` ; `no time zone N in the zone database (DIR): ...` ; `Trunc takes a unit of ...` ; `Avg is for ints, floats, money and dates, not a T` ; `Quantile's fraction is from 0 to 1, not P` ; `Sort's keys are not a Values column: it is a list` | un fuseau, une unité, un type ou une fraction d'un rapport qui n'en est pas un ([les rapports](cesia.md#les-rapports--avg-countx-values-quantile-variance-stddev-trunc) ; chaque message plus haut, dans `Find` et `Watch`) | un nom de fuseau IANA (`"Europe/Paris"`), une unité de la liste, un agrégat d'un type qu'il prend |
| `invalid` | `Sum of invoice/Total passed the 63 bits of an Int in the group "Lyon": group by a finer key, or ask its Avg and Count (exact)` ; `Trunc of invoice/Due to the year of date D: its unit starts before the least date, ...` | une `Sum` dont le total exact dans un groupe est au-delà de $\pm 2^{62}$ (les centimes de 46 billiards d'euros, 4,6 unités d'une `Money(18)`), dans `Find`, ou à l'écriture qui fait passer au-delà une somme surveillée (ce watch finit, les autres continuent) ; un `Trunc` d'une date 146 millions d'années avant 1970 dont l'unité commence avant la plus petite date ([les agrégats](cesia.md#find--les-questions)) | un groupe plus fin, ou `Avg` et `Count()` : exacts, leur produit donne le total en floats |
| `invalid` | `NAME links to K things only, and #T is not one`; `the K #X cannot be deleted while the L #Y links to it (NAME: refuse)`; le budget de travail d'un `Delete` | un lien vers une chose d'un autre kind ; une suppression qu'un lien refuse ; une cascade trop grande pour un seul groupe ([supprimer une chose](cesia.md#supprimer-une-chose)) | pointer vers une chose du kind ; supprimer d'abord ce qui pointe vers elle |
| `denied` | `this token may not add to the kind K, which a deletion of a J reaches`; `this token may not read the kind K, whose links refuse the deletion of a J`; `this token may not read the kind K, which NAME links to` | un token qui a des droits par kind : un `Delete` (ou un retrait d'un fait d'un kind que des liens nomment) qui peut atteindre un kind qu'il ne peut pas écrire, ou parler d'un qu'il ne peut pas lire ; un lien vers un kind qu'il ne peut pas lire | un token qui a ces droits ([les droits](server.md#les-droits-g16)) |
| `timeout` | `the question took more than N s, its time: ask a narrower one, or give it more time` | la question a dépassé son `timeout`, ou le `question_timeout` du serveur (un temps plus long que celui du serveur ne compte que d'un token admin) : dans la mémoire du programme ou au serveur, pareil | une question plus étroite, ou des pages ; un `timeout` plus long là où le serveur le permet |
| `invalid` | `Prefix is for a text, not a T`; `Prefix takes 1 to 1024 bytes, not N`; `variable N of Prefix is the value of no pattern` | `Prefix` sur un autre type, un préfixe vide ou trop long | une variable texte que donne un pattern |
| `invalid` | `Limit: at most 100000 rows a page, not N`; `In takes at most 100000 values, not N`; `a question takes at most 64 operators and their items, not N`; `a question's Ors make N questions to ask (the product of their alternatives): at most 64` | les bornes d'une question ([limites](limits.md#les-questions)) | demander page par page, découper la liste, ou poser plusieurs questions |
| `too_large` | `the question passed the server's budget of N candidates: ask a narrower one, or several` | une question dont le join (la jointure des patterns) énumère plus que le budget du serveur, ses lookups (ses recherches dans un index) divisés par le plus grand nombre de patterns d'une même variable ([limites](limits.md#les-questions)) ; un watch (une question vivante, tenue à jour) qui le dépasse à une frame (par ses Not, Or ou In, ou par le remplissage de sa fenêtre) se termine par elle | une question plus étroite : plus de constantes, un intervalle, un Limit sur le chemin de l'index |
| `too_large` | `the answer passed the server's budget of N cells (rows times columns): ask a narrower question, or pages with Sort, Limit and After` | un Find avec Sort ou des agrégats, ou la première réponse d'un watch, dont le serveur tiendrait les lignes au-delà de sa borne ([limites](limits.md#les-questions)) ; un Find sans Sort n'est jamais refusé pour sa taille (au-delà, il est envoyé à mesure que ses lignes sont trouvées) | des pages (`Sort`, `Limit`, `After`), ou un Find sans Sort |
| `too_large` | `the answers the server is building hold its budget of N cells: ask again in a moment, or a narrower question` | les réponses tenues de toutes les connexions ensemble sont à la borne du serveur | redemander |
| `too_large` | `a connection keeps 1024 watches at most: unwatch one first`; `the server keeps 65536 watches at most: ...`; `the watches of a connection keep N cells at most (their windows' rows and their groups): ...`; `the watches of the server keep N cells at most: ...` | un Watch au-delà des watches d'une connexion ou du serveur, ou au-delà des lignes que gardent leurs fenêtres et leurs groupes ([limites](limits.md#le-serveur)) | un Unwatch de ce que le programme ne montre plus ; un Limit plus petit |
| `invalid` | `a name has at most 255 bytes, not N` | une propriété ou une règle déclarée à travers le serveur avec un nom plus long | un nom plus court |
| `too_large` | `a text has at most 16773120 bytes, not N` | un texte à travers le serveur au-delà de la limite des frames moins 4 KiB | un fichier dans le vault (`Put`) |
| `too_large` | `a group of N new things: its receipt would pass the frame limit of 16777216 bytes; write them in several groups` | un groupe dont le reçu ne tiendrait pas dans une frame ; rien n'est appliqué | plusieurs groupes |
| `too_large` | `a row of N bytes is over the frame limit of 16777152: give fewer of its texts at once` | un Find (ou un watch) dont une ligne seule dépasse une frame | donner moins de colonnes de texte |
| `invalid` | `a question has at most 64 patterns, not N: ask several, or name a part with a rule` | une question de plus de patterns, refusée par le client avant d'être envoyée (celle d'un client écrit à la main est refusée par le serveur, qui ferme la connexion) | la découper, ou nommer une partie avec une règle |
| `invalid` | `a watch has no After: its rows are the first of its order, as they change`; `a watch's Limit needs Sort: the engine's order is no order a watch can keep`; `a watch of aggregates keeps every group: Sort and Limit are for a watch of Give` | `Watch` avec After, avec Limit sans Sort, ou avec Sort ou Limit et des agrégats | un watch de `Give` avec `Sort` (et `Limit`) ; pour la page suivante, `Find` avec `After` |
| `invalid` | `a watch has no windows (Running, Rank, Prev) or Each: each row's value hangs on the rows before it, so one change would change every row after it; watch the question without them, or ask Find again at each change` | `Watch` avec une fenêtre ou `Each` | surveiller la question sans elles et les calculer dans le programme, ou `Find` à nouveau à chaque changement |
| `invalid` | `this server speaks protocol N: a watch with Sort and Limit needs a server of protocol 5` | un watch avec Sort ou Limit, sur une connexion à un serveur d'une version antérieure : refusé avant d'être envoyé | mettre à jour le serveur ([mises à jour](production.md#les-mises-à-jour)), ou suivre la question sans eux |
| `invalid` | `H is reached over the network: give the cluster's certificate authority, ca = "/etc/cepheus/ca.pem"` | Connect par TCP sans `ca` | le `ca.pem` du cluster (créé par `cepheus cluster init`) |
| `invalid` | `a fork starts from Empty, another fork, or a database read on the server's machine; this one is read at the server` | un Fork d'une base atteinte par le réseau | faire un fork de `cepheus.Empty`, ou tourner sur la machine du serveur |
| `invalid` | `OWL 2 RL's rules need its vocabulary: give owl.Vocabulary to Connect (or Fork)` | `Define` de `owl.Rl()` sur une base sans le kind `owl` | ajouter `owl.Vocabulary` à la liste de Connect, ou de Fork |
| `invalid` | `P is declared in this database otherwise than in OWL 2 RL's vocabulary` | une propriété `owl/...` déclarée avec un autre type, `many` ou `unique` | une base dont les propriétés `owl/` sont celles d'OWL 2 RL |
| `invalid` | `N is no rule of OWL 2 RL: owl.Rl() gives its rules` | une map `{Rule, Library: "owl"}` d'un nom que la bibliothèque n'a pas | les maps de `owl.Rl()` |
| `conflict` | `owl:Thing and owl:Nothing could not be made: Define again` | d'autres programmes les ont créées et supprimées pendant que `Define` les créait, trois fois | refaire Define |
| `conflict` | `cepheus.Same: the class of N changed while it was read: read it again` | par le réseau, une classe défaite entre les deux questions que pose `Same` | appeler `Same` à nouveau |
| `closed` | `this database was closed` | un appel sur une base après `cepheus.Close` | se reconnecter avec Connect |
| `unreachable` | `no Cepheus server answers at ADDRESS: REASON` | Connect : rien n'écoute au socket ou au port de l'hôte, ou ce qui écoute ne répond pas au handshake (la poignée de main qui ouvre la connexion) en 5 s (REASON `no answer within 5 s`, ou `the TLS handshake: Resource temporarily unavailable`) | démarrer le serveur, vérifier l'adresse |
| `unreachable` | `the server did not answer for 30 s (REASON): a write in flight was applied once or not at all` | un appel après que la connexion a cassé et est restée cassée pendant tout le budget de nouvelles tentatives | démarrer le serveur ; relire avant d'écrire à nouveau |
| `protocol` | `an unexpected reply to Get` (Find, Write) | le serveur a répondu par une autre sorte de réponse : un bug | le signaler |

Une faute dans la forme d'un appel est un bug du programme, pas une valeur d'erreur : elle arrête la fiber, comme
`bug.Panic`, avec le message de Cesia, comme `cepheus.Get needs a database, as cepheus.Connect or Fork gives it, not the
number 3.` Celles du package : une base, un kind (`as cepheus.Kind made it`), une propriété (`as Client.City`), une map,
une liste, une opération (`as cepheus.Add, Retract, Expect or Incr makes it`), le `into` d'un `Incr` (`[thing, property], as
[cepheus.New(1), Invoice.Number]`), une question (`{Where: [patterns], Give:
{Name: variable}}`), un pattern (`[thing, property, value], or Above, Below or Between`), une variable ou l'identifiant
d'une chose en premier dans un pattern, une variable ou un agrégat dans Give ; et à `cepheus.Kind` : un nom qui n'est
pas fait de lettres minuscules, de chiffres, de `_` et de `-`, aucun champ, un champ nommé `kind`, un type qui n'est
aucun de `Text()`, `Int()`, `Float()`, `Bool()`, `Date()`, `Link()`, `Money(scale)`, une échelle hors de 0 à 18, un
`to` qui n'est pas un nom de kind, un `onDelete` sans `to` ou autre que `"refuse"`, `"cascade"` et `"clear"` ; à
`cepheus.Connect` : une adresse qui n'est pas `cepheus://host:port/database` (avec `?socket=DIR` pour seul
paramètre) ; à `cepheus.Find` : plus de 12 variables.

## Les lignes sur la sortie d'erreur

Un merge tourne en arrière-plan ; quand il échoue, il le dit sur la sortie d'erreur standard, supprime son fichier, et
la base continue avec ses anciens runs (aucune erreur n'atteint un client) ; le merge suivant attend que le delta ait
grandi d'un seuil de plus. D'autres lignes viennent du writer et du commit buffer.

| ligne | quand |
|---|---|
| `cepheus: the journal could not be cut back after a failed write: MSG` | après une écriture ou un fsync du journal qui a échoué, le retour à la dernière frame durable a échoué aussi : les écritures qui ont échoué peuvent revenir à la réouverture (G13) |
| `cepheus: the journal could not be forced at close: MSG` | le fsync d'un journal partagé (celui d'une base qui écrit par le commit buffer) a échoué à la fermeture : pas de marqueur `closed`, et la prochaine ouverture est une recovery |
| `cepheus: the commit buffer could not be cut back after a failed write: MSG` | après une écriture ou un fsync du buffer qui a échoué, son retour au dernier round forcé a échoué aussi : le round qui a échoué peut revenir au prochain démarrage |
| `cepheus: the commit buffer could not be emptied: MSG` | un arrêt propre n'a pas pu supprimer `DATA/server.wal.1` ou `.2` : le prochain démarrage les lit, et trouve leurs frames déjà dans les journaux |
| `cepheus: the run of a large group could not be named: MSG` | le renommage du fichier de run d'un grand groupe a échoué après que sa frame était durable : la base s'arrête (`Io`), et l'ouverture suivante rejoue le groupe depuis le journal |
| `cepheus: background merge failed: EXN` | le domain du merge a rencontré une exception (une erreur de disque, une page illisible) |
| `cepheus: a merge could not be installed: MSG` | le renommage ou le fsync du répertoire a échoué |
| `cepheus: a merge could not catch up: MSG` | une page n'a pas pu être lue pendant le replay des groupes écrits pendant le merge |
| `cepheus: ready in T ms: ...` | le serveur a démarré : le temps de ses ouvertures, le groupe de chaque base, ses écoutes et ses domains |
| `cepheus: FILE reloaded: N tokens` / `cepheus: FILE not reloaded: MSG` | tokens.toml a changé ; un fichier qui ne se lit pas n'est pas pris, le serveur garde les tokens qu'il avait |
| `cepheus: database NAME: the sessions could not be saved: MSG` | le checkpoint des sessions a échoué (une erreur de disque) : l'ancien reste, et le démarrage suivant lit davantage du journal |
| `cepheus: stopping` / `cepheus: stopped` | SIGTERM ou SIGINT : l'arrêt du [serveur](server.md#démarrage-arrêt-crash) |
| `cepheus: connection N (token T), request I of kind K failed: EXN` | une requête a rencontré ce que le serveur n'attendait pas (un bug, la mémoire épuisée) : elle a reçu la réponse `internal` et sa connexion a été fermée ([le serveur](server.md#une-requête-qui-fait-échouer-le-serveur)). EXN est le texte de l'exception, coupé à 300 octets, chaque octet hors de l'ASCII imprimable écrit `\ddd` |
| `cepheus: connection N (token T) failed: EXN` | la même chose dans un autre thread de la connexion (la réponse à une écriture, un push, un message que le serveur envoie sans demande) ou dans sa boucle de lecture : `internal` sur la requête d'id 0, puis la connexion se ferme |
| `cepheus: a watched question at a frame failed: EXN` | une question suivie a échoué à une frame : ses watches se terminent par `internal`, les autres questions continuent |
| `cepheus: the watches of a database failed: EXN` | le hub (le thread qui calcule les questions vivantes d'une base) a échoué hors d'une question : chaque watch de la base se termine par `internal`, et un nouveau watch part de l'état de la frame |
| `cepheus: a connection's thread failed: EXN` / `cepheus: a connection's start failed: EXN` | ce qu'aucun rattrapage d'exception d'une connexion n'attendait, après la fermeture de son socket ; ou aucun thread n'a pu être créé pour une nouvelle connexion (la limite du système) : elle est fermée tout de suite |
| `cepheus: a write's reply failed: EXN` / `cepheus: the receipt of a write in its session's table failed: EXN` | l'issue d'une écriture n'a pas pu être transmise, ou gardée dans la table de sa session (la mémoire) : ceux qui l'attendent reçoivent leur réponse quand même |
| `... (and N failures since the line before, not written)` | les lignes ci-dessus viennent au plus une fois par seconde : la suivante compte celles qui ont été laissées de côté |
| `cepheus: slow question: database D, token T, MS ms, N candidates[, R rows], OUTCOME: SHAPE` | une question (un Find, la première réponse d'un watch) a pris `[log] slow_ms` ou plus au serveur : son issue (`ok` ou le code de son erreur), ses candidats, ses lignes (celles d'un Find), et sa forme, chaque constante écrite `?` ([les questions lentes](production.md#les-questions-et-les-écritures-lentes)) |
| `cepheus: slow write: database D, token T, MS ms[, group G], OUTCOME: N operations (...) of PROPERTIES` | une écriture a pris `[log] slow_ms` ou plus, de sa requête à sa réponse une fois son groupe durable |
| `... (and N slow questions or writes not written since the line before)` | les lignes lentes viennent au plus 10 par seconde : la suivante compte celles laissées de côté (`cepheus status` les compte toutes) |
