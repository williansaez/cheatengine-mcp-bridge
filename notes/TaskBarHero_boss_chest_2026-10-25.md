# TaskBarHero via Cheat Engine MCP: achados de 2026-10-24 e 2026-10-25

Endereços de heap e de módulo mudam a cada execução do jogo (PID 19784 nesta sessão).
Offsets e nomes de classe valem até o jogo atualizar.

## 1. Ambiente e ferramentas

- Bridge: `ce_mcp_bridge.lua` no CE, pipe `\\.\pipe\CE_MCP_Bridge_v99`, um cliente só. Chamadas longas (varredura de classes) derrubam a ponte em certas classes de dados do compilador.
- `mono_image_enumClasses` pode voltar vazio logo após reiniciar o dissector. Solução: `LaunchMonoDataCollector()` + `sleep(2000)`.
- `mono_compile_method` + `disassemble` + `splitDisassembledString` + `getInstructionSize` permitem varrer chamadas. Varredura completa (~2200 classes) leva ~20 chamadas.
- Hook de thread principal (`mcp_req`): AA em `SlotInteractionManager.Update`, prólogo `40 53 48 83 EC 20`. Estado 1=pedido, 2=ocupado, 3=feito. Some quando o jogo reinicia.
- Breakpoints:
  - `set_breakpoint` (hardware, registro): não pausa o jogo, registra registradores e pilha. Limite: 4 slots de debug.
  - `debug_setBreakpoint` (CE, pausador): pausa o jogo no hit. Usar com confirmação.
  - Breakpoint de registro gera milhares de hits em métodos chamados muitas vezes. Ler os hits com `get_breakpoint_hits` gera arquivo grande: filtrar com PowerShell.
- Code folding (ICF): o mesmo endereço pode ser dois métodos (`BoxData..ctor(UInt64,EBoxType)` e `EffectUsageKey..ctor` estão em 7FFE957D4B70). Sempre confirmar pelo `mono_method_getSignature`, não só pelo símbolo.

## 2. Estrutura do jogo (IL2CPP, Unity 6000.0.72)

Classes e métodos obfuscados (`vs`, `xs`, `cm`, `ldp`...), mas tipos, assinaturas e enums legíveis.

### Heróis e status
- `Pstat` = AOB em GameAssembly.dll (padrão de código). `[Pstat]` = klass `vo`; `+0xB8` estáticos: `+0x20` Dict<heroType, xs>, `+0x28` Dict<slot, xs>, `+0x38` herói selecionado.
- Herói `xs`: `+0x10` bcp (stats), `+0x30` HeroInfoData, `+0x88` Hero.
- `bcp+0x20` = Dictionary<statId, float>. Dano = id 1, Velocidade = 2, Crítico = 3, PV = 5, Defesa = 6, etc.
- Métodos de `xs`: `fxz(slot)` (equipado), `ldp(slot, id)` (equipar), `lie(slot)` (desequipar, destrutivo).
- Slots de equipamento do herói (0-based): 0 arma, 2 elmo, 3 armadura, 4 luvas, 5 botas.

### Itens e inventário
- Item `vs`: `+0x10` ItemInfoData (`+0x30` key, `+0x40` slot 1-based, `+0x44` EGearType, `+0x78` nome).
- `vu.jzm(ulong id)` retorna o item por id (estático).
- Chave do item: `xxG011` (xx = categoria/subtipo, G = grau: 0 comum, 1 incomum, 2 raro).
- Enums: EGearType 1 SWORD, 2 BOW, 3 STAFF, 4 SCEPTER, 10 TOME, 13 HELMET, 14 ARMOR, 15 GLOVES, 16 BOOTS. EEquipClassType 0 All, 1 Knight, 2 Ranger, 3 Sorcerer, 4 Priest. ESlotType 1 INVENTORY, 2 STASH, 5 GEAR.
- Bolsa: 28 slots, `vq.jti(i)` -> `xv`; `xv+0x18` InventorySaveData {+0x18 ItemUniqueId (ulong), +0x24 Quantity}.
- Baú (stash): `Stash.lax(tab)` -> List<StashCache> (49 slots por aba, abas 0 a 5). `StashCache+0x18` -> StashSaveData.
- Mover bolsa para baú: `StashCache.lbn(cacheVazio, id, qty)` (retorna slot) + `xv.lbr()` (limpa slot da bolsa). Verificado sem duplicatas.
- Remover do baú: `Stash.lam(id)`.
- Dicionário de todos os itens: `bfi.bkwv` = `Dictionary<int, ItemInfoData>` (capacidade 8419, 7031 entradas ocupadas). Exportado em `notes\tbh_item_ids.csv`: chaves únicas, nomes confiáveis só em 509 casos.

### Caixas (loot boxes)
- `StageBox` (`TaskbarHero.UI`): `+0x48` EBoxType (0 NORMAL, 1 BOSS, 2 ACTBOSS), `+0x4C` EContentType (0 NONE, 1 PLAGUE, 2 EVENT).
- Caixa ativa (visível): `get_isActiveAndEnabled` (`UnityEngine.Behaviour`) retorna 1. Usar isso para escolher o que abrir. Objetos antigos continuam no heap depois de usados.
- Abertura: `StageBox.nzm(this, int)` (clique) -> `nzn` -> `<TryOpen>d__88.MoveNext` -> `vq.OpenBoxAsync` / `vq.ExchangeOpenBoxAsync`.
- `OpenBoxAsync` lê `BoxData.get_RewardItemId` e `get_RewardItemUniqueID` antes de qualquer sorteio. Depois chama `vl.jqv` (`AddItemResult`) e `vl.jqt`, que usa `BackendPostItem`.
- `BoxData`: `itemId` +0x54, `rewardItemId` +0x68 (plain), `o_rewardItemId` +0x30 (ofuscado pelo ACTk, não decifrado). Não tem setter de `RewardItemId`.
- Caixas por tipo ficam em `yx` (`Dictionary<EBoxType, List<BoxData>>`): `yx.dop`, `yx.zq`, `yx.lsc` adicionam.
- Varredura de caixas: 19 candidatos no heap em uma leitura; só alguns estavam ativos por vez.

### Estágio e morte
- `StageManager.jeh(int, EStageType, int, float, EMonsterType)`: é o **spawn** do monstro (chamado por `MonsterSpawnManager.nby`). Cria `BoxData` via `p..ctor`, busca item em `bfi.ozo`, atualiza `yx`. Não tem constante de EBoxType.
- `StageManager.jcr(Unit, ...) -> bool`: chama `nby` (spawn de onda). Dispara muitas vezes por segundo.
- `StageManager.jer` / `jes(DeadUnitData, float)`: tratam o **herói** caído (`DeadUnitData.ctor(xs, int)`, tempo de ressurreição). Não são a morte do monstro.
- `MonsterSpawnManager.ncc(Unit)`: teste de breakpoint não disparou na morte.
- `Monster.hbd(Unit) -> bool` e `Unit.hbd(Unit) -> bool`: disparam muitas vezes durante a luta. Não são o gatilho.
- `bcr.mrm` / `bcr.mrl(float, EContentType) -> float`: multiplicadores por tipo de conteúdo. Podem ser relevantes para chance de drop. Não confirmado.
- Estágio: `StageClearFunction` (request/result com `StageKey`, `PlagueStageKey`), `<ClaimStageBoxAsync>`, `<ExchangeStageBoxAsync>`, `<RetryStageClearAsync>`.

### Caixa ACTBOSS (morte do boss)
- Construtor `BoxData(UInt64, EBoxType)` em `7FFE957D4B70` (mono). O símbolo IL2CPP desse endereço é `EffectUsageKey..ctor` (ICF).
- Breakpoint de registro no construtor: na morte do boss aparece **um hit com `R8 = 2`** (ACTBOSS). Duas lutas registradas: ts 1792894319 (ou 1792894323) e 1792895029.
- Os hits com `R8 = 4, 6, 8, 10, 12, 16...` são de outros construtores/chamadas (EffectUsageKey e outros). Não são a caixa.
- Chamadores diretos do construtor (pilha de hits): helper `0x7FFE95440D80` (39 bytes, leaf) e `0x7FFE954B534B` (188 bytes, leaf). Esses helpers são chamados por ponteiro (a pilha mostra endereços de heap na origem).
- Varredura de chamadas diretas aos dois helpers em todas as classes (1 a 2200): nenhum chamador. A chamada é indireta.
- Endereços de heap na pilha da criação (`0x260E9554630`, `0x260E89E0C30`): classe `AnimationCurve`, não delegate de evento.
- **Gatilho da morte do boss: não identificado.** Próximo passo sugerido: procurar pelo lado da animação do boss (classes `ActBoss*`, `ActBossMonsterStab`, `MonsterActive`) e pelos métodos que tratam fim de luta. Sem disparar nada.

### Save
- `SaveFile_Live.es3` (`%USERPROFILE%\AppData\LocalLow\TesseractStudio\TaskBarHero\`): criptografado (Easy Save 3). Sem chave, não dá para ler.

## 3. Rede e servidor

Captura: `pktmon` (nativo do Windows), precisa de administrador. O filtro por IP vê só aquele endereço.

Conexões do processo do jogo observadas:
- `3.39.167.199:443` (AWS): conexão principal no início. Heartbeat de 36 bytes (~18 s).
- `15.165.195.76:443`, `13.124.191.80:443`, `3.35.118.186:443`, `43.200.166.97:443`, `172.67.179.47:443`, `2.19.54.18:443`: outros hosts usados depois.

Testes:
- Bloquear `3.39.167.199` (regra `TBH test block`): o jogo passou para outros hosts AWS; a caixa abriu normalmente.
- Bloquear `15.165.195.76` (regra `TBH test block 2`): o jogo fechou/reiniciou. Regras removidas no fim.
- Captura sem filtro durante a abertura: pacotes de 396 bytes para `15.165.195.76` em 01:01:37.805, no mesmo instante da abertura. Conteúdo cifrado, não provado que é o pedido da caixa.
- Conclusão: a abertura provavelmente passa pelo servidor. A conclusão antiga "recompensa local" estava errada (filtro só por um IP).

## 4. Itens e nomes confirmados
- `309171` = `SWORD_300017` = Dimensional Sword (Cosmic, nível 80), segundo o wiki taskbarhero.wiki. Atributos: dano base +2659, velocidade +0,63/s, mod Shield Charge Kill Cooldown. Valor de revenda: 398.279.840 ouro.

## 5. O que foi recusado e por quê
- Recriar a chamada que gera a caixa de boss, ou chamar `StageManager.jeh`, `BoxData` ou o construtor à mão, para criar recompensa sem a morte: forjar evento de jogo que o backend valida. Recusado, mesmo com a proposta de apagar a recompensa depois.
- Trocar o id do item de uma recompensa já recebida: não testado. Risco de dessincronia com o servidor.
- Mudar a chance de drop: não é possível pelo cliente (a recompensa já vem definida em `BoxData`).

## 6. Pendências
- Gatilho da morte do boss (ver seção 2).
- Quem registra o evento que chama `StageManager.jeh` e `bcr.mrm`/`mrl`.
- Decifrar `ObscuredLong`/`ObscuredInt` (ACTk) para ler `o_rewardItemId`.
- Confirmar, com captura sem filtro e horário exato, se a abertura fala com `15.165.195.76`.
- Equipar os itens novos e gastar pontos de habilidade do mago (não pedido ainda).
