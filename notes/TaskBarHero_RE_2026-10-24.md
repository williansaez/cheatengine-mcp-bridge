# TaskBarHero via Cheat Engine MCP — tudo que foi aprendido em 2026-10-24

Sessão única: setup do bridge, análise de duas cheat tables, automação da UI, engenharia reversa do IL2CPP e controle total do jogo (ler inventário/baú/status, equipar, abrir caixas) só pelo MCP. Endereços de heap mudam a cada execução do jogo; offsets, padrões de código e nomes de classe/método valem até o jogo atualizar.

## 1. Ambiente e setup

- Bridge: `MCP_Server/ce_mcp_bridge.lua` carregado no CE (`File -> Execute Script`), servidor Python `MCP_Server/mcp_cheatengine.py`. Deps instaladas no venv `C:\Users\willi\AppData\Local\hermes\hermes-agent\venv` (é o `python` do PATH). O servidor foi registrado no Claude Code com esse interpretador explícito:
  `claude mcp add --scope user cheatengine -- <venv>\Scripts\python.exe <repo>\MCP_Server\mcp_cheatengine.py`
- Pipe `\\.\pipe\CE_MCP_Bridge_v99` aceita **um cliente**. Com a sessão do Claude conectada, `test_mcp.py` falha com "Todas as instâncias de pipes estão ocupadas". Pra rodar a suíte, fechar a sessão ou remover o servidor MCP temporariamente. A suíte escreve memória no processo anexado: usar um processo descartável.
- Jogo: `TaskBarHero.exe` em `D:\SteamLibrary\steamapps\common\TaskbarHero`, Unity 6000.0.72.12797, IL2CPP (`GameAssembly.dll` ~114 MB), 64-bit, Steam overlay carregado, CodeStage ACTk (tipos Obscured).
- Recarregar o bridge por dentro: `evaluate_lua` com `dofile([[...\ce_mcp_bridge.lua]])` funciona; a chamada em andamento pode cair e a próxima reconecta.

## 2. Melhoria feita no bridge (commit 05d29d6)

`set_data_breakpoint` passou a capturar call stack por hit (`capture_stack`, default ligado, `stack_depth` 16), no Lua e no Python. Motivo: hit em watchpoint sem pilha não diz quem acessou. Primeira versão do diff colocou o default no breakpoint de execução por engano; corrigido antes do commit.

## 3. Lições sobre CE/bridge (genéricas)

- **Breakpoints só pelo bridge.** `debug_setBreakpoint` chamado via `evaluate_lua` registra, mas o callback nunca roda, e um hit congela o alvo (dinheiro/EXP param) até `debug_continueFromBreakpoint(co_run)`. Limpar com `debug_removeBreakpoint(addr)` + continue.
- `executeCodeEx` retorna `nil` nesse CE; não serve pra chamar funções do jogo. Solução: hook de thread principal (seção 7).
- `AOBScan` do Lua não enxerga páginas copy-on-write do GameAssembly (slots estáticos); o `scan_all` do bridge com `protection="+W"` enxerga. `AOBScan` retorna `nil` quando não acha.
- `splitDisassembledString(d)` retorna `(extra, opcode, bytes, address)`, nessa ordem.
- A janela "Lua Engine" do CE abre sozinha quando `evaluate_lua` produz saída e cobre o jogo (parece máscara cinza no screenshot). `getLuaEngine().hide()` no fim de cada script.
- `getNameFromAddress` não resolve nomes IL2CPP; montei um mapa endereço→"classe.método(params)" com o dissector (seção 6).
- `get_breakpoint_hits` com milhares de hits é inviável; `serverState` é local do bridge e não dá pra filtrar por Lua. Preferir watchpoints de dados (poucos hits) ou breakpoint condicional implementado no próprio bridge.
- Resposta do `evaluate_lua` precisa ser UTF-8 válido: nomes de classe ofuscados em unicode e legendas de janela em PT-BR derrubam a chamada. Sanitizar com `gsub("[\128-\255]","?")`.
- Timeout por chamada do bridge é 30 s: lotes de no máximo ~10 operações de 1–2 s por `evaluate_lua`.

## 4. Automação de UI (olhos = computer-use, mãos = bridge)

- Computer-use precisa de grant pro basename `taskbarhero.exe` (o nome Steam "TBH Task Bar Hero" não bate com a janela) e "File Explorer" pra clicar na barra de tarefas. Janela do Claude maximizada cobre o jogo e aparece como máscara cinza.
- **Espaço de coordenadas**: CE roda sem DPI-awareness. Com tela 2560x1440 a 200%, `getMousePos/setMousePos` usam 1280x720, igual ao screenshot do computer-use. Pixel do print = coordenada do CE. `get_screen_info` reporta 2560x1080 e engana.
- Clique pelo bridge: `executeCodeLocalEx("user32.mouse_event", flags, dx, dy, 0, 0)`. Hover precisa ser real: `setMousePos` teleporta sem `WM_MOUSEMOVE` e o Unity não dispara pointer-enter (tooltip e clique direito não funcionam). Usar movimento absoluto `0x8001` com `dx=x*65535/1280`, `dy=y*65535/720`, conferir `getMousePos()` antes de clicar. Esquerdo `0x0002/0x0004`, direito `0x0008/0x0010`. Movimento relativo `0x0001` é atenuado pela precisão do ponteiro.
- Botões flutuantes de loot exigem aproximação lenta (3–4 movimentos, ~500 ms parado, press de ~90 ms); slots de item aceitam clique rápido.
- Sair da janela do jogo direto pelo cursor deixa tooltip presa; estacionar num ponto neutro dentro do jogo (ex.: cabeçalho do painel).
- Se o cursor "desvia" entre leituras, é mão humana no mouse ou janela movida: re-screenshot antes de continuar. Tab abre o menu do jogo.
- Mapa de UI (painel HERO em x 330–645 quando aberto no meio): cabeçalho (423,94)=Trade Ship, (453,94)=Estatísticas globais, (659,94)=config, (689,94)=fechar; retratos da party (458/486/514, 245); inventário 7 colunas x≈366..607, linhas y≈303/343/383; abas Inventário/Formação; botões da base: 1º baú=STASH, 2º cruz=STATUS (lupa (110,243) abre atributos detalhados), 4º=CUBE. Os dois baús flutuantes abaixo do painel são caixas de loot (azul=BOSS, marrom=NORMAL), não o STASH.
- Mecânica (confirmada pelo usuário): clique direito no item equipa, mas só sem painel lateral (CUBE/STASH) aberto. Tooltip de hover mostra o item lado a lado com o EQUIPPED. X vermelho = classe errada; bolinha vermelha = item novo. Inventário desloca slots quando um item sai.

## 5. Cheat tables analisadas

- **ColonelRVH v1.0 (2026-06-05)**: AOBs em GameAssembly.dll ainda batem. Money único; Skill Points (5 hits) e HP (2 hits) usam `aobscanmodule` e podem pegar o hit errado; EXP depende do símbolo IL2CPP `uf.jio`.
- **Jonxpin test.ct**: cobertura maior e trata multi-hit, mas o script principal escaneia `TaskBarHero.exe` em vez de `GameAssembly.dll` (0 hits) e a cadeia do Pstat está um campo deslocada (`+B8,+40,...` → correto `+B8,+38,...`). O "ACTk Bypass" contém Lua ofuscado (`v15("LOL!...")`) que roda com acesso total ao sistema: não ativar.
- Offsets do "Stage (Info Only)" do test.ct batem: Act +48, StageNo +4C, StageLevel +50, WaveAmount +54, etc. (ponteiro capturado por breakpoint em `8B 49 4C 48 8D 54 24 40`).
- Dinheiro é `ObscuredLong`; lido decifrado no RAX no hit da AOB `48 8D 4C 24 40 48 8D 14 30` (+20 por tick ~3 s).

## 6. IL2CPP pelo dissector do CE (o que destravou tudo)

`LaunchMonoDataCollector()` funciona com IL2CPP. Depois:
- `mono_findClass(ns, nome)`, `mono_class_enumFields(k)` (nome, offset, tipo, estático), `mono_class_enumMethods(k)`, `mono_method_getSignature(m)` → `(params, names, ret)` após `pcall`, `mono_compile_method(m)` → endereço.
- Classes e métodos do jogo têm nomes ofuscados (`vs`, `xs`, `cm`, `ldp`...), mas **tipos de campo, assinaturas e nomes de enum não**. Isso basta pra identificar tudo.
- Classes de UI mantêm nomes reais (`TaskbarHero.UI.StageBox`, `InventorySlot`, `GearSlot`, `UI_RemakeStash`, `ItemTooltip`).
- Instâncias: AOB pelo ponteiro da klass (`+W-C`, alinhado 8) e filtrar `monitor==0` em `+8`.
- Nome de classe de um objeto: `[obj]`=klass, `[klass+0x10]`=nome, `[klass+0x18]`=namespace. Arrays têm `[]` no nome.
- Seguir cadeia de chamadas: desmontar com `disassemble` e mapear alvos de `call` no mapa endereço→método.

Enums: `EGearType` 1 SWORD, 2 BOW, 3 STAFF, 4 SCEPTER, 10 TOME, 13 HELMET, 14 ARMOR, 15 GLOVES, 16 BOOTS. `EEquipClassType` 0 All, 1 Knight, 2 Ranger, 3 Sorcerer, 4 Priest. `ESlotType` 0 NONE, 1 INVENTORY, 2 STASH, 3 TRADINGSTASH, 4 CUBEINVENTORY, 5 GEAR, 6 MATERIALSTASH. `EBoxType` 0 NORMAL, 1 BOSS, 2 ACTBOSS. `EContentType` 0 NONE, 1 PLAGUE, 2 EVENT. `EGradeType` 0 COMMON, 1 UNCOMMON, 2 RARE, 3 LEGENDARY, ... Key de item `xxG011`: G = grau.

## 7. Hook de thread principal (chamar funções do jogo)

Auto Assembler em `SlotInteractionManager.Update` (prólogo `40 53 48 83 EC 20`). Bloco `mcp_req` (64 bytes): `+0` estado (1=pedido, 2=ocupado, 3=feito), `+8` rcx/this, `+0x10` edx (dword), `+0x18` r8, `+0x20` endereço da função, `+0x28` rax de retorno. O stub salva registradores, alinha a pilha, chama com r9=0 e marca 3. Chamar: escrever campos, estado=1, poll até 3 (timeout 3–5 s). Roda no thread do Unity a cada frame; verificado com `vu.jzm(2082)` retornando o objeto esperado. Script completo no helper `taskbarhero_mcp_equip.lua` (scratchpad da sessão). Para desinstalar, bloco `[DISABLE]` restaura os 6 bytes; reload do bridge ou fechar o jogo também desfaz.

## 8. Estruturas e funções descobertas

Raiz estável (padrão de código, não heap):
- `Pstat` = 1º hit em GameAssembly.dll de `48 8B 05 ?? ?? ?? ?? 83 B8 E4 00 00 00 00 75 ?? 48 8B C8 E8 ?? ?? ?? ?? 48 8B 05 ?? ?? ?? ?? 48 8B 80 B8 00 00 00 48 8B 48 20 48 85 C9 74 ?? 48 8B 15 ?? ?? ?? ?? E8`; `Pstat = hit+7+rel32@hit+3` (hoje GA+0x615CC50). `[Pstat]` = klass `vo`; `[klass+0xB8]` = estáticos: `+0x20` Dict<tipoHerói 101..601, xs>, `+0x28` Dict<slot 1..6, xs>, `+0x38` herói selecionado.

Herói `xs`: `+0x10 bcp`, `+0x30 HeroInfoData` (`+0x30` id, `+0x38` "HeroName_301"), `+0x88 TaskbarHero.Hero`, `+0xB8 HashSet<ObscuredULong>`, `+0x140 ObscuredULong[12]` (slots, cifrado). `bcp+0x20` = Dictionary<statId,float> (entradas de 16 bytes). Ids: 1 Dano, 2 VelAtq, 3 Crit, 4 DanoCrit, 5 PVmax, 6 Defesa, 7 VelMov, 8 AoE%, 10 CDR, 16 Esquiva, 17 Bloqueio, 21 LifeLeech, 23 HPregen, 24–28 dano fís/fogo/frio/raio/caos, 34 DmgRed, 40 DmgAbs, 50 SkillHeal, 52 ResElem, 55 AoEDmg, 58 PV/kill.

Métodos de `xs`: `fxz(int slot)->ulong` GetEquippedId (getter puro); `ldp(int slot, ulong id)->bool` Equip (aliases irg/lhy/mcv/ooe); `lie(int slot)->ulong` Unequip (destrutivo); `ym(vs)->bool` CanEquip; `lir(ulong)` aplica mods. Slots do herói 0-based: 0 arma, 2 elmo, 3 armadura, 4 luvas, 5 botas. `ItemInfoData+0x40` é o mesmo índice 1-based.

Item `vs`: `+0x10 ItemInfoData` (`+0x30` key, `+0x40` slot 1-based, `+0x44` EGearType, `+0x78` id string), `+0x20` Dict<EGearGroup, List<StatModGroupInfoData>>, `+0x28 .bag`, `+0x30 EEquipClassType`, `+0x60.. 5× GearModData` (ACTk, não decifrado). Registro global: `vu.bipc` static Dict<ulong, vs>; `vu.jzm(ulong id)->vs` (estático) pega por id. Dict `cm+0x200` lista todos os itens (raiz estática não identificada).

Baú: `Stash.lax(int aba)->List<StashCache>` (49 slots/aba, abas 0..5), `StashCache+0x18 -> StashSaveData {+0x10 Index, +0x18 ItemUniqueId, +0x20 IsUnLock, +0x24 Quantity}`. `Stash.lam(ulong id)` remove o id de qualquer slot. `StashCache.lbn(cache, id, qty)->slot` escreve num slot vazio. `Stash.lav/lat` e `Stash.lah` não fizeram o que parecia. `Stash.laq()` é contagem de abas.

Bolsa: 28 slots; `vq.jti(int i)->xv`; `xv+0x18 -> InventorySaveData` (mesmo layout do StashSaveData); `xv.lbr()` limpa o slot. "Guardar Tudo" = `sj.itt(this=sj, 1 INVENTORY, 2 STASH)` (método de instância; só enche a aba atual).

Caixas de loot: `TaskbarHero.UI.StageBox` (5 instâncias; `+0x48` EBoxType, `+0x4C` EContentType). `nzm(this, 0)` = clique esquerdo: abre e manda o item pra bolsa (fluxo assíncrono, ~1 s). `countText` e `vq.juq()` não são contadores ao vivo; medir pelo crescimento da bolsa; ícone flutuante some quando o tipo esgota.

Caminho do clique na UI (pra referência): `InventorySlot.nue` → `SlotInteractionManager.ixo/ixt/ixu` → `ixx` (SlotActionContext) → `so.ivw/ivx` → `so.iwl` (vq.jul, bolsa), `so.iwh` (Stash.lav), `so.iwi` (Stash.lau), `so.iwj` (wb.kbx, material), `so.iwk` (Cube). Equipar passa por `MoveRequest` (`sj.itf/iti/iuf/iuq`). `xy` = trading stash, `wb` = material stash, `vq` = caixas/bolsa, `zw` = rekey/enchant.

## 9. Receitas prontas

- **Ler status**: Pstat → statics+0x28 → xs → bcp+0x20 → entradas.
- **Ler equipamento**: `fxz(xs, slot)` por slot via hook; nome via `vu.jzm(id)` → ItemInfoData+0x78.
- **Equipar**: `ldp(xs, slot, id)` → `Stash.lam(id)` (tira do baú) → se trocou, `StashCache.lbn(vazio, idAntigo, 1)` (senão o antigo vira órfão).
- **Ler baú/bolsa**: `lax(aba)` / `jti(i)`.
- **Esvaziar bolsa**: `lbn(vazio, id, qty)` + `lbr(xv)` por item (sem duplicatas, verificado).
- **Abrir caixas**: `nzm(StageBox, 0)` em loop, 2,5 s de espera por drop, parar quando a bolsa não cresce.

## 10. Estado do jogo ao fim do dia

Cavaleiro: espada 2100 (Incomum), elmo 2088 (Incomum), armadura 2032, luvas 2080 (Incomum), botas 2126 (Incomum) — Dano 28,8, PV 150, Def 245,7. Explorador: arco 2082 (Incomum), elmo 2098 (Incomum), armadura 2102, luvas 2110 (Incomum), botas 2148 — Dano 32, PV 80, Def 189. Feiticeiro: cajado 2112 (Incomum), elmo 2040, armadura 2094, luvas 2030 (Incomum), botas 2034 — Dano 30,6, Def 174,1, 38 pontos de habilidade sem gastar. Baú: 49/48/46/5 itens nas abas 0–3, bolsa 0/28, sem duplicatas. Loot novo não equipado: elmo Raro 502011, botas Raras 532011 ×2, armadura 511011, cetro 331011, espada 301011, luvas 521011 ×2, botas 531011. Hook `mcp_req` segue instalado.

## 11. Pendências

- Raiz estática do inventário (`cm`) não resolvida; redescoberta por scan a cada run.
- Decifrar ObscuredULong/GearModData (XOR simples não funciona nessa versão do ACTk).
- Equipar os Raros/Incomuns novos e gastar os pontos de habilidade.
