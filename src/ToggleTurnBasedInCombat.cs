using System;
using System.Collections.Generic;
using System.Reflection;
using System.Text;
using UnityEngine;

[assembly: AssemblyTitle("Toggle Turn-Based In Combat")]
[assembly: AssemblyProduct("Toggle Turn-Based In Combat")]
[assembly: AssemblyVersion("1.1.2.0")]
[assembly: AssemblyFileVersion("1.1.2.0")]

namespace LoomToggleTurnBasedInCombat
{
    // Sidecar entry point. Assembly-CSharp is patched to call Bootstrap.Tick() at the top of
    // GameState.Update(); on first tick we spawn a persistent MonoBehaviour that does the work.
    public static class Bootstrap
    {
        private static bool s_spawned;

        public static void Tick()
        {
            if (s_spawned)
            {
                return;
            }

            try
            {
                GameObject go = new GameObject("LoomToggleTurnBasedInCombat");
                UnityEngine.Object.DontDestroyOnLoad(go);
                go.AddComponent<Toggler>();
            }
            catch (Exception ex)
            {
                Debug.LogError("[LoomToggleTurnBasedInCombat] spawn failed: " + ex);
            }
            finally
            {
                s_spawned = true;
            }
        }
    }

    // Makes Pillars' turn-based ("Tactical") mode fully combat-friendly:
    //   1) The native TACTICAL_TOGGLE keybind (Options -> Controls, vanilla default T) flips the mode
    //      any time, including mid-combat. The engine's own AI loop enrolls/tears down combatants.
    //   2) The vanilla center-bottom HUD toggle button (which normally hides in combat) is kept
    //      visible and clickable in combat.
    //
    // KEYBIND CONTRACT: this mod never writes a binding. It only READS the player's bound
    // TACTICAL_TOGGLE control, so whatever they set in Options -> Controls is what works. The one
    // thing it disables is the HUD button's own UIButtonKeyBinding, whose keyCode is hardcoded on
    // the prefab and therefore ignores that binding: leaving it on would both double-fire the
    // default key and keep a stale key live after a rebind. The button itself stays fully
    // clickable - UIButtonKeyBinding is a keyboard-only shim and has no part in mouse input.
    //
    // The button is found by FUNCTION, not name: it's the GameObject whose UIOptionsSetter targets
    // GameOption.BoolOption.TACTICAL_PSEUDO_TOGGLE. Its click handler (GameMode.SetOption) has no
    // combat guard, so once it's visible it just works.
    public class Toggler : MonoBehaviour
    {
        private string m_status = string.Empty;
        private float m_statusUntil;

        // When we enable tactical mode mid-combat, the engine never fires OnCombatStart (combat is
        // already active), so the manager's turn machine is never kicked: combatants enroll but no
        // turn order / initiative / first turn ever spins up. We supply that missing kick ourselves
        // by calling NotifyEventOrderChanged() each frame until the machine reports it's live,
        // bounded by a short deadline so we never spin forever.
        private float m_kickUntil;

        // Cached vanilla HUD toggle button + the visibility components we neutralise.
        private GameObject m_button;
        private readonly List<UIVisibleInCombat> m_hiders = new List<UIVisibleInCombat>();
        private float m_nextButtonScan;
        private bool m_loggedButton;

        private void Update()
        {
            try
            {
                if (!GameState.IsInGameSession || GameState.IsLoading)
                {
                    return;
                }

                if (GameInput.GetControlDown(MappedControl.TACTICAL_TOGGLE))
                {
                    Toggle();
                }

                KickTurnMachineIfPending();
                MaintainButton();
            }
            catch (Exception ex)
            {
                Debug.LogError("[LoomToggleTurnBasedInCombat] update failed: " + ex);
            }
        }

        private void Toggle()
        {
            TacticalMode current = GameState.Option.TacticalMode;
            bool enabling = current == TacticalMode.Disabled;
            TacticalMode next = enabling ? TacticalMode.RoundBased : TacticalMode.Disabled;

            GameState.Option.TacticalMode = next;
            GameState.OnTacticalModeChanged.Trigger(next);

            if (enabling)
            {
                if (GameState.InCombat)
                {
                    // Kick the turn machine over the next few frames, once the AI loop has enrolled
                    // the current combatants (which it does because ShouldBeInTacticalCombat is now
                    // true). Vanilla does this via OnCombatStart, which won't re-fire mid-fight.
                    m_kickUntil = Time.realtimeSinceStartup + 3f;
                    Flash("Turn-based (Tactical) mode: ON  (starting turns)");
                }
                else
                {
                    Flash("Turn-based (Tactical) mode: ON");
                }
            }
            else
            {
                m_kickUntil = 0f; // turning off cancels any pending kick
                Flash("Real-time with pause: ON");
            }
        }

        private void KickTurnMachineIfPending()
        {
            if (m_kickUntil <= 0f)
            {
                return;
            }

            // Abort if the situation no longer applies (mode turned off, combat ended, timed out).
            if (Time.realtimeSinceStartup > m_kickUntil
                || GameState.Option.TacticalMode == TacticalMode.Disabled
                || !GameState.InCombat)
            {
                m_kickUntil = 0f;
                return;
            }

            TacticalModeManager mgr = TacticalModeManager.Instance;
            if (mgr == null)
            {
                return;
            }

            // NotifyEventOrderChanged() rebuilds turn order, sets m_isPartyMemberInCombat, and spins
            // up the first turn. Once the machine reports it's live, we're done.
            mgr.NotifyEventOrderChanged();
            if (TacticalModeManager.IsInTacticalCombat())
            {
                m_kickUntil = 0f;
            }
        }

        // Locate the vanilla tactical toggle button and keep it visible/clickable at all times
        // (in particular, in combat, where UIVisibleInCombat would otherwise fade it to alpha 0).
        private void MaintainButton()
        {
            if (m_button == null)
            {
                if (Time.realtimeSinceStartup < m_nextButtonScan)
                {
                    return;
                }
                m_nextButtonScan = Time.realtimeSinceStartup + 2f; // don't hammer FindObjects
                FindButton();
                if (m_button == null)
                {
                    return;
                }
            }

            // Keep the hide-in-combat driver off and force full opacity every frame (cheap; the
            // cached component list means no per-frame FindObjects).
            for (int i = 0; i < m_hiders.Count; i++)
            {
                UIVisibleInCombat v = m_hiders[i];
                if (v == null) { continue; }
                if (v.enabled) { v.enabled = false; }
                SetAlpha(v.gameObject, 1f);
            }

            Collider col = m_button.GetComponent<Collider>();
            if (col != null && !col.enabled) { col.enabled = true; }
        }

        private void FindButton()
        {
            try
            {
                UIOptionsSetter[] setters = Resources.FindObjectsOfTypeAll<UIOptionsSetter>();
                foreach (UIOptionsSetter s in setters)
                {
                    if (s == null || s.gameObject.hideFlags != HideFlags.None) { continue; } // skip prefab assets
                    if (s.BoolSuboption != GameOption.BoolOption.TACTICAL_PSEUDO_TOGGLE) { continue; }

                    m_button = s.gameObject;

                    // Collect the visibility drivers: prefer ones on the button/its children; only
                    // fall back to the nearest ancestor if the button itself carries none.
                    m_hiders.Clear();
                    m_hiders.AddRange(m_button.GetComponentsInChildren<UIVisibleInCombat>(true));
                    if (m_hiders.Count == 0)
                    {
                        UIVisibleInCombat[] up = m_button.GetComponentsInParent<UIVisibleInCombat>(true);
                        if (up.Length > 0) { m_hiders.Add(up[0]); } // nearest ancestor
                    }

                    // If the button carries its own hardcoded key, disable it: our poll of the
                    // menu-bound TACTICAL_TOGGLE is the single hotkey path, so two handlers on the
                    // same key can't cancel each other out.
                    int killedBinds = 0;
                    foreach (UIButtonKeyBinding kb in m_button.GetComponents<UIButtonKeyBinding>())
                    {
                        if (kb != null && kb.enabled) { kb.enabled = false; killedBinds++; }
                    }

                    if (!m_loggedButton)
                    {
                        m_loggedButton = true;
                        StringBuilder sb = new StringBuilder();
                        sb.Append("[LoomToggleTurnBasedInCombat] tactical button = ").Append(PathOf(m_button.transform));
                        sb.Append(" | hiders(").Append(m_hiders.Count).Append("):");
                        foreach (UIVisibleInCombat v in m_hiders)
                        {
                            if (v != null) { sb.Append(" [").Append(PathOf(v.transform)).Append(" invert=").Append(v.Invert).Append("]"); }
                        }
                        sb.Append(" | disabled ").Append(killedBinds).Append(" UIButtonKeyBinding");
                        Debug.Log(sb.ToString());
                    }
                    return;
                }
            }
            catch (Exception ex)
            {
                Debug.LogError("[LoomToggleTurnBasedInCombat] FindButton failed: " + ex);
            }
        }

        private static void SetAlpha(GameObject go, float a)
        {
            UIPanel panel = go.GetComponent<UIPanel>();
            if (panel != null) { panel.alpha = a; }
            UIWidget widget = go.GetComponent<UIWidget>();
            if (widget != null) { widget.alpha = a; }
        }

        private static string PathOf(Transform t)
        {
            StringBuilder sb = new StringBuilder(t.name);
            Transform p = t.parent;
            while (p != null)
            {
                sb.Insert(0, p.name + "/");
                p = p.parent;
            }
            return sb.ToString();
        }

        private void Flash(string msg)
        {
            m_status = msg;
            m_statusUntil = Time.realtimeSinceStartup + 3f;
        }

        private void OnGUI()
        {
            if (string.IsNullOrEmpty(m_status) || Time.realtimeSinceStartup >= m_statusUntil)
            {
                return;
            }

            GUIStyle style = new GUIStyle(GUI.skin.label)
            {
                fontSize = 16,
                fontStyle = FontStyle.Bold
            };
            style.normal.textColor = Color.cyan;
            GUI.Label(new Rect(12f, 8f, 640f, 26f), ">> " + m_status, style);
        }
    }
}
