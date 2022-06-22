package com.sourcegraph.find;

import com.intellij.ide.IdeEventQueue;
import com.intellij.ide.ui.UISettings;
import com.intellij.openapi.Disposable;
import com.intellij.openapi.actionSystem.ActionManager;
import com.intellij.openapi.actionSystem.AnAction;
import com.intellij.openapi.actionSystem.CommonShortcuts;
import com.intellij.openapi.application.ApplicationManager;
import com.intellij.openapi.project.DumbAwareAction;
import com.intellij.openapi.project.Project;
import com.intellij.openapi.project.ProjectManager;
import com.intellij.openapi.project.ProjectManagerListener;
import com.intellij.openapi.ui.DialogWrapper;
import com.intellij.openapi.ui.popup.ActiveIcon;
import com.intellij.openapi.ui.popup.JBPopup;
import com.intellij.openapi.ui.popup.JBPopupFactory;
import com.intellij.openapi.util.DimensionService;
import com.intellij.openapi.util.Disposer;
import com.intellij.openapi.wm.WindowManager;
import com.intellij.openapi.wm.impl.IdeFrameImpl;
import com.intellij.openapi.wm.impl.IdeGlassPaneImpl;
import com.intellij.ui.PopupBorder;
import com.intellij.ui.TitlePanel;
import com.intellij.ui.WindowMoveListener;
import com.intellij.ui.WindowResizeListener;
import com.intellij.ui.awt.RelativePoint;
import com.intellij.ui.components.JBPanel;
import com.intellij.util.containers.ContainerUtil;
import com.intellij.util.ui.JBUI;
import com.intellij.util.ui.UIUtil;
import com.sourcegraph.Icons;
import org.jetbrains.annotations.NotNull;
import org.jetbrains.annotations.Nullable;

import javax.swing.*;
import javax.swing.border.Border;
import java.awt.*;
import java.awt.event.ActionEvent;
import java.util.List;

public class ForkedFindPopupPanel extends JBPanel<ForkedFindPopupPanel> {
    private static final String SERVICE_KEY = "sourcegraph.find.popup.2";
    @NotNull
    private final Project myProject;
    @NotNull
    private final Disposable myDisposable;
    private DialogWrapper myDialog;

    private FindContentPanel findContentPanel;

    ForkedFindPopupPanel(Project project, FindContentPanel findContentPanel) {
        super(new BorderLayout());
        myProject = project;
        this.findContentPanel = findContentPanel;
        myDisposable = Disposer.newDisposable();
        initComponents();
    }

    public void showUI() {
        if (myDialog != null && myDialog.isVisible()) {
            return;
        }
        if (myDialog != null && !myDialog.isDisposed()) {
            myDialog.doCancelAction();
        }
        if (myDialog == null || myDialog.isDisposed()) {
            myDialog = new DialogWrapper(this.myProject, null, true, DialogWrapper.IdeModalityType.MODELESS, false) {
                {
                    init();
                    getRootPane().setDefaultButton(null);
                }

                @Override
                protected void doOKAction() {
                    System.out.println("Do OK Action");
                }

                @Override
                protected void dispose() {
                    super.dispose();
                }

                @Nullable
                @Override
                protected Border createContentPaneBorder() {
                    return null;
                }

                @Override
                protected JComponent createCenterPanel() {
                    return ForkedFindPopupPanel.this;
                }

                @Override
                protected String getDimensionServiceKey() {
                    return SERVICE_KEY;
                }
            };
            myDialog.setUndecorated(true);
            ApplicationManager.getApplication().getMessageBus().connect(myDialog.getDisposable()).subscribe(ProjectManager.TOPIC, new ProjectManagerListener() {
                @Override
                public void projectClosed(@NotNull Project project) {
                    closeImmediately();
                }
            });
            Disposer.register(myDialog.getDisposable(), myDisposable);

            Window window = WindowManager.getInstance().suggestParentWindow(myProject);
            Component parent = UIUtil.findUltimateParent(window);
            RelativePoint showPoint = null;
            Point screenPoint = DimensionService.getInstance().getLocation(SERVICE_KEY);
            if (screenPoint != null) {
                if (parent != null) {
                    SwingUtilities.convertPointFromScreen(screenPoint, parent);
                    showPoint = new RelativePoint(parent, screenPoint);
                } else {
                    showPoint = new RelativePoint(screenPoint);
                }
            }
            if (parent != null && showPoint == null) {
                int height = UISettings.getInstance().getShowNavigationBar() ? 135 : 115;
                if (parent instanceof IdeFrameImpl && ((IdeFrameImpl) parent).isInFullScreen()) {
                    height -= 20;
                }
                showPoint = new RelativePoint(parent, new Point((parent.getSize().width - getPreferredSize().width) / 2, height));
            }
            WindowMoveListener windowListener = new WindowMoveListener(this);
            addMouseListener(windowListener);
            addMouseMotionListener(windowListener);
            Dimension panelSize = getPreferredSize();
            Dimension prev = DimensionService.getInstance().getSize(SERVICE_KEY);
//            panelSize.width += JBUIScale.scale(24);//hidden 'loading' icon
//            panelSize.height *= 2;
            if (prev != null && prev.height < panelSize.height) prev.height = panelSize.height;
            Window dialogWindow = myDialog.getPeer().getWindow();
            AnAction escape = ActionManager.getInstance().getAction("EditorEscape");
            JRootPane root = ((RootPaneContainer) dialogWindow).getRootPane();

            IdeGlassPaneImpl glass = (IdeGlassPaneImpl) myDialog.getRootPane().getGlassPane();
            WindowResizeListener resizeListener = new WindowResizeListener(
                root,
                JBUI.insets(4),
                null) {
                private Cursor myCursor;

                @Override
                protected void setCursor(@NotNull Component content, Cursor cursor) {
                    if (myCursor != cursor || myCursor != Cursor.getDefaultCursor()) {
                        glass.setCursor(cursor, this);
                        myCursor = cursor;

                        if (content instanceof JComponent) {
                            IdeGlassPaneImpl.savePreProcessedCursor((JComponent) content, content.getCursor());
                        }
                        super.setCursor(content, cursor);
                    }
                }
            };
            glass.addMousePreprocessor(resizeListener, myDisposable);
            glass.addMouseMotionPreprocessor(resizeListener, myDisposable);

            DumbAwareAction.create(e -> closeImmediately())
                .registerCustomShortcutSet(escape == null ? CommonShortcuts.ESCAPE : escape.getShortcutSet(), root, myDisposable);
            root.setWindowDecorationStyle(JRootPane.NONE);
            root.setBorder(PopupBorder.Factory.create(true, true));
            UIUtil.markAsPossibleOwner((Dialog) dialogWindow);
            dialogWindow.setBackground(UIUtil.getPanelBackground());
            dialogWindow.setMinimumSize(panelSize);
//            if (prev == null) {
//                panelSize.height *= 1.5;
//                panelSize.width *= 1.15;
//            }
            dialogWindow.setSize(prev != null ? prev : panelSize);

            IdeEventQueue.getInstance().getPopupManager().closeAllPopups(false);
            if (showPoint != null) {
                myDialog.setLocation(showPoint.getScreenPoint());
            } else {
                dialogWindow.setLocationRelativeTo(null);
            }
            myDialog.show();

            JRootPane rootPane = getRootPane();
            if (rootPane != null) {
                rootPane.getActionMap().put("openInFindWindow", new AbstractAction() {
                    @Override
                    public void actionPerformed(ActionEvent e) {
                        System.out.println("open in find window");
                    }
                });
            }
        }
    }

    protected boolean canBeClosed() {
        if (myProject.isDisposed()) return true;
        if (!ApplicationManager.getApplication().isActive()) return false;
        if (KeyboardFocusManager.getCurrentKeyboardFocusManager().getFocusedWindow() == null) return false;
        List<JBPopup> popups = ContainerUtil.filter(JBPopupFactory.getInstance().getChildPopups(this), popup -> !popup.isDisposed());
        if (!popups.isEmpty()) {
            for (JBPopup popup : popups) {
                popup.cancel();
            }
            return false;
        }
        return true;
    }

    private void initComponents() {
        JLabel icon = new JLabel(new ActiveIcon(Icons.Logo));
        TitlePanel titlePanel = new TitlePanel(new ActiveIcon(Icons.Logo).getRegular(), new ActiveIcon(Icons.Logo).getInactive());
        titlePanel.setText("Sourcegraph");
        icon.setVerticalAlignment(SwingConstants.TOP);

        add(titlePanel, BorderLayout.NORTH);
        add(this.findContentPanel, BorderLayout.CENTER);
    }

    private void closeImmediately() {
        if (canBeClosedImmediately() && myDialog != null && myDialog.isVisible()) {
            myDialog.doCancelAction();
        }
    }

    //Some popups shown above may prevent panel closing, first of all we should close them
    private boolean canBeClosedImmediately() {
        return myDialog != null && canBeClosed();
    }

    public void hidePopup() {
        myDialog.getPeer().getWindow().setVisible(false);
    }

    public void showPopup() {
        myDialog.show();
    }
}
