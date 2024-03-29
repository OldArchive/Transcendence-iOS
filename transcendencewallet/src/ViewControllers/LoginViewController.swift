//
//  LoginViewController.swift
//  breadwallet
//
//  Created by Adrian Corscadden on 2017-01-19.
//  Copyright © 2017 breadwallet LLC. All rights reserved.
//

import UIKit
import LocalAuthentication

private let biometricsSize: CGFloat = 32.0
private let topControlHeight: CGFloat = 32.0

class LoginViewController : UIViewController, Subscriber, Trackable {

    //MARK: - Public
    var walletManager: WalletManager? {
        didSet {
            guard walletManager != nil else { return }
            pinView = PinView(style: .login, length: store.state.pinLength)
        }
    }
    var shouldSelfDismiss = false
    init(store: Store, isPresentedForLock: Bool, walletManager: WalletManager? = nil) {
        self.store = store
        self.walletManager = walletManager
        self.isPresentedForLock = isPresentedForLock
        self.disabledView = WalletDisabledView(store: store)
        if walletManager != nil {
            self.pinView = PinView(style: .login, length: store.state.pinLength)
        }
        super.init(nibName: nil, bundle: nil)
    }

    deinit {
        store.unsubscribe(self)
    }

    //MARK: - Private
    private let store: Store
    private let backgroundView = UIView() //LoginBackgroundView()
    private let pinPad = PinPadViewController(style: .clear, keyboardType: .pinPad, maxDigits: 0)
    private let pinViewContainer = UIView()
    private var pinView: PinView?
    private let addressButton = ShadowButton(title: "", type: .tertiary, image: #imageLiteral(resourceName: "ReceiveButtonIcon"), imageColor: .gradientStart, backColor: .grayBackground)
    private let scanButton = ShadowButton(title: "", type: .tertiary, image: #imageLiteral(resourceName: "SendButtonIcon"), imageColor: .grayTextTint, backColor: .grayBackground)
    private let isPresentedForLock: Bool
    private let disabledView: WalletDisabledView
    private let activityView = UIActivityIndicatorView(activityIndicatorStyle: .whiteLarge)

    private var logo: UIImageView = {
        let image = UIImageView(image: #imageLiteral(resourceName: "LogoFront"))
        image.contentMode = .scaleAspectFill
        return image
    }()

    private let biometrics: UIButton = {
        let button = UIButton(type: .system)
        button.tintColor = .grayTextTint
        button.setImage(LAContext.biometricType() == .face ? #imageLiteral(resourceName: "FaceId") : #imageLiteral(resourceName: "TouchId"), for: .normal)
        button.layer.masksToBounds = true
        button.accessibilityLabel = LAContext.biometricType() == .face ? S.UnlockScreen.faceIdText : S.UnlockScreen.touchIdText
        return button
    }()
    private let subheader = UILabel(font: .customBody(size: 16.0), color: .white)
    private var pinPadPottom: NSLayoutConstraint?
    private var topControlTop: NSLayoutConstraint?
    private var unlockTimer: Timer?
    private let pinPadBackground = UIView() //GradientView()
    private let topControlContainer: UIView = {
        let view = UIView()
        view.layer.borderColor = UIColor.white.cgColor
        view.layer.borderWidth = 1.0
        view.layer.cornerRadius = 5.0
        view.layer.masksToBounds = true
        let separator = UIView()
        view.addSubview(separator)
        separator.backgroundColor = .white
        separator.constrain([
            separator.topAnchor.constraint(equalTo: view.topAnchor),
            separator.bottomAnchor.constraint(equalTo: view.bottomAnchor),
            separator.centerXAnchor.constraint(equalTo: view.centerXAnchor),
            separator.widthAnchor.constraint(equalToConstant: 1.0) ])
        return view
    }()
    private var hasAttemptedToShowBiometrics = false
    private let lockedOverlay = UIVisualEffectView()
    private var isResetting = false

    override func viewDidLoad() {
        addSubviews()
        addConstraints()
        addBiometricsButton()
        addPinPadCallback()
        if pinView != nil {
            addPinView()
        }
        disabledView.didTapReset = { [weak self] in
            guard let store = self?.store else { return }
            guard let walletManager = self?.walletManager else { return }
            self?.isResetting = true
            let nc = UINavigationController()
            let recover = EnterPhraseViewController(store: store, walletManager: walletManager, reason: .validateForResettingPin({ phrase in
                let updatePin = UpdatePinViewController(store: store, walletManager: walletManager, type: .creationWithPhrase, showsBackButton: false, phrase: phrase)
                nc.pushViewController(updatePin, animated: true)
                updatePin.resetFromDisabledWillSucceed = {
                    self?.disabledView.isHidden = true
                }
                updatePin.resetFromDisabledSuccess = {
                    self?.authenticationSucceded()
                }
            }))
            recover.addCloseNavigationItem()
            nc.viewControllers = [recover]
            nc.navigationBar.tintColor = .darkText
            nc.navigationBar.titleTextAttributes = [
                NSAttributedStringKey.foregroundColor: UIColor.darkText,
                NSAttributedStringKey.font: UIFont.customBold(size: 17.0)
            ]
            nc.setClearNavbar()
            nc.navigationBar.isTranslucent = false
            nc.navigationBar.barTintColor = .whiteTint
            nc.viewControllers = [recover]
            self?.present(nc, animated: true, completion: nil)
        }
        store.subscribe(self, name: .loginFromSend, callback: {_ in 
            self.authenticationSucceded()
        })
    }

    override func viewDidAppear(_ animated: Bool) {
        super.viewDidAppear(animated)
        guard UIApplication.shared.applicationState != .background else { return }
        if shouldUseBiometrics && !hasAttemptedToShowBiometrics && !isPresentedForLock && UserDefaults.hasShownWelcome {
            hasAttemptedToShowBiometrics = true
            biometricsTapped()
        }
        if !isResetting {
            lockIfNeeded()
        }
      
    }
    private func showSyncView() {
        guard let window = UIApplication.shared.keyWindow else { return }
        let mask = UIView(color: .transparentBlack)
        mask.alpha = 0.0
        window.addSubview(mask)
        mask.constrain(toSuperviewEdges: nil)
        
        let syncView = SyncingView()
        syncView.backgroundColor = .darkGray
        syncView.layer.cornerRadius = 4.0
        syncView.layer.masksToBounds = true
        
        store.subscribe(self, selector: { $0.walletState.syncProgress != $1.walletState.syncProgress },
                        callback: { state in
                            syncView.timestamp = state.walletState.lastBlockTimestamp
                            syncView.progress = CGFloat(state.walletState.syncProgress)
        })
        mask.addSubview(syncView)
        syncView.constrain([
            syncView.leadingAnchor.constraint(equalTo: window.leadingAnchor, constant: C.padding[2]),
            syncView.topAnchor.constraint(equalTo: window.topAnchor, constant: 136.0 + C.padding[2]),
            syncView.trailingAnchor.constraint(equalTo: window.trailingAnchor, constant: -C.padding[2]),
            syncView.heightAnchor.constraint(equalToConstant: 88.0) ])
        
        UIView.animate(withDuration: C.animationDuration, animations: {
            mask.alpha = 1.0
        })
        
        DispatchQueue.main.asyncAfter(deadline: .now() + 3.0, execute: {
            mask.removeFromSuperview()
            self.dismiss(animated: true, completion: nil)
        })
    }
    override func viewDidDisappear(_ animated: Bool) {
        super.viewDidDisappear(animated)
        unlockTimer?.invalidate()
    }

    private func addPinView() {
        guard let pinView = pinView else { return }
        pinViewContainer.addSubview(pinView)
        view.addSubview(subheader)
        pinView.constrain([
            pinView.centerYAnchor.constraint(equalTo: view.centerYAnchor, constant: E.isIPhone4 ? -C.padding[2] : 0.0),
            pinView.centerXAnchor.constraint(equalTo: pinViewContainer.centerXAnchor),
            pinView.widthAnchor.constraint(equalToConstant: pinView.width),
            pinView.heightAnchor.constraint(equalToConstant: pinView.itemSize) ])
        subheader.constrain([
            subheader.bottomAnchor.constraint(equalTo: pinView.topAnchor, constant: -C.padding[1]),
            subheader.centerXAnchor.constraint(equalTo: view.centerXAnchor) ])
    }

    private func addSubviews() {
        view.addSubview(backgroundView)
        view.addSubview(pinViewContainer)
        view.addSubview(addressButton)
        view.addSubview(scanButton)
        view.addSubview(logo)
        if walletManager != nil {
            view.addSubview(pinPadBackground)
        } else {
            view.addSubview(activityView)
        }
    }

    private func addConstraints() {
        backgroundView.constrain(toSuperviewEdges: nil)
        backgroundView.backgroundColor = .grayBackground
        if walletManager != nil {
            addChildViewController(pinPad, layout: {
                pinPadPottom = pinPad.view.bottomAnchor.constraint(equalTo: view.bottomAnchor, constant: -C.marginBottom)
                pinPad.view.constrain([
                    pinPad.view.leadingAnchor.constraint(equalTo: view.leadingAnchor),
                    pinPad.view.trailingAnchor.constraint(equalTo: view.trailingAnchor),
                    pinPadPottom,
                    pinPad.view.heightAnchor.constraint(equalToConstant: pinPad.height) ])
            })
        }
        pinViewContainer.constrain(toSuperviewEdges: nil)

        addressButton.constrain([
            addressButton.topAnchor.constraint(equalTo: view.topAnchor, constant: C.marginTop),
            addressButton.leadingAnchor.constraint(equalTo: view.leadingAnchor, constant: C.padding[5] + 10.0) ])
        scanButton.constrain([
            scanButton.topAnchor.constraint(equalTo: addressButton.topAnchor),
            scanButton.trailingAnchor.constraint(equalTo: view.trailingAnchor, constant: -C.padding[5]) ])
        logo.constrain([
            logo.topAnchor.constraint(equalTo: addressButton.bottomAnchor, constant: C.padding[8]),
            logo.centerXAnchor.constraint(equalTo: view.centerXAnchor),
            logo.heightAnchor.constraint(equalTo: logo.widthAnchor, multiplier: C.Sizes.logoAspectRatio),
            logo.widthAnchor.constraint(equalTo: view.widthAnchor, multiplier: 0.55) ])
        if walletManager != nil {
            pinPadBackground.backgroundColor = .grayBackground
            pinPadBackground.constrain([
                pinPadBackground.leadingAnchor.constraint(equalTo: pinPad.view.leadingAnchor),
                pinPadBackground.trailingAnchor.constraint(equalTo: pinPad.view.trailingAnchor),
                pinPadBackground.topAnchor.constraint(equalTo: pinPad.view.topAnchor),
                pinPadBackground.bottomAnchor.constraint(equalTo: pinPad.view.bottomAnchor) ])
        } else {
            activityView.constrain([
                activityView.centerXAnchor.constraint(equalTo: view.centerXAnchor),
                activityView.centerYAnchor.constraint(equalTo: view.centerYAnchor, constant: -20.0) ])
            activityView.startAnimating()
        }
        subheader.text = S.UnlockScreen.subheader
        
        addressButton.tintColor = .gradientStart
        scanButton.tintColor = .grayTextTint
        addressButton.addTarget(self, action: #selector(addressTapped), for: .touchUpInside)
        scanButton.addTarget(self, action: #selector(scanTapped), for: .touchUpInside)
    }

    private func addBiometricsButton() {
        guard shouldUseBiometrics else { return }
        view.addSubview(biometrics)
        biometrics.addTarget(self, action: #selector(biometricsTapped), for: .touchUpInside)
        biometrics.constrain([
            biometrics.widthAnchor.constraint(equalToConstant: biometricsSize),
            biometrics.heightAnchor.constraint(equalToConstant: biometricsSize),
            biometrics.trailingAnchor.constraint(equalTo: view.trailingAnchor, constant: -C.padding[2]),
            biometrics.bottomAnchor.constraint(equalTo: pinPad.view.topAnchor, constant: -C.padding[2]) ])
    }

    private func addPinPadCallback() {
        pinPad.ouputDidUpdate = { [weak self] pin in
            guard let myself = self else { return }
            guard let pinView = self?.pinView else { return }
            let attemptLength = pin.utf8.count
            pinView.fill(attemptLength)
            self?.pinPad.isAppendingDisabled = attemptLength < myself.store.state.pinLength ? false : true
            if attemptLength == myself.store.state.pinLength {
                self?.authenticate(pin: pin)
            }
        }
    }

    private func authenticate(pin: String) {
        guard let walletManager = walletManager else { return }
        guard !E.isScreenshots else { return authenticationSucceded() }
        guard walletManager.authenticate(pin: pin) else { return authenticationFailed() }
        authenticationSucceded()
    }

    private func authenticationSucceded() {
        saveEvent("login.success")
        let label = UILabel(font: subheader.font)
        label.textColor = .whiteTint
        label.text = S.UnlockScreen.unlocked
        label.alpha = 0.0
        let lock = UIImageView(image: #imageLiteral(resourceName: "unlock"))
        lock.alpha = 0.0

        view.addSubview(label)
        view.addSubview(lock)

        label.constrain([
            label.bottomAnchor.constraint(equalTo: lock.topAnchor, constant: -C.padding[3]),
            label.centerXAnchor.constraint(equalTo: view.centerXAnchor) ])
        lock.constrain([
            lock.centerYAnchor.constraint(equalTo: view.centerYAnchor),
            lock.centerXAnchor.constraint(equalTo: label.centerXAnchor) ])
        view.layoutIfNeeded()

        UIView.spring(0.6, animations: {
            self.pinPadPottom?.constant = self.pinPad.height
            self.topControlTop?.constant = -100.0
            lock.alpha = 1.0
            label.alpha = 1.0
            self.addressButton.alpha = 0.0
            self.scanButton.alpha = 0.0
//            self.touchId.alpha = 0.0
            self.logo.alpha = 0.0
            self.subheader.alpha = 0.0
            self.pinView?.alpha = 0.0
            self.view.layoutIfNeeded()
        }) { completion in
            if self.shouldSelfDismiss {
                self.dismiss(animated: true, completion: nil)
            }
            self.store.perform(action: LoginSuccess())
            self.store.trigger(name: .showStatusBar)
        }
    }

    private func authenticationFailed() {
        saveEvent("login.failed")
        guard let pinView = pinView else { return }
        pinPad.view.isUserInteractionEnabled = false
        pinView.shake { [weak self] in
            self?.pinPad.view.isUserInteractionEnabled = true
        }
        pinPad.clear()
        DispatchQueue.main.asyncAfter(deadline: .now() + pinView.shakeDuration) { [weak self] in
            pinView.fill(0)
            self?.lockIfNeeded()
        }
    }

    private var shouldUseBiometrics: Bool {
        guard let walletManager = self.walletManager else { return false }
        return LAContext.canUseBiometrics && !walletManager.pinLoginRequired && store.state.isBiometricsEnabled
    }

    @objc func biometricsTapped() {
        guard !isWalletDisabled else { return }
        walletManager?.authenticate(biometricsPrompt: S.UnlockScreen.touchIdPrompt, completion: { result in
            if result == .success {
                self.authenticationSucceded()
            }
        })
    }

    @objc func addressTapped() {
        store.perform(action: RootModalActions.Present(modal: .loginAddress))
    }

    @objc func scanTapped() {
        store.perform(action: RootModalActions.Present(modal: .loginScan))
    }

    private func lockIfNeeded() {
        if let disabledUntil = walletManager?.walletDisabledUntil {
            let now = Date().timeIntervalSince1970
            if disabledUntil > now {
                saveEvent("login.locked")
                let disabledUntilDate = Date(timeIntervalSince1970: disabledUntil)
                let unlockInterval = disabledUntil - now
                let df = DateFormatter()
                df.setLocalizedDateFormatFromTemplate(unlockInterval > C.secondsInDay ? "h:mm:ss a MMM d, yyy" : "h:mm:ss a")

                disabledView.setTimeLabel(string: String(format: S.UnlockScreen.disabled, df.string(from: disabledUntilDate)))

                pinPad.view.isUserInteractionEnabled = false
                unlockTimer?.invalidate()
                unlockTimer = Timer.scheduledTimer(timeInterval: unlockInterval, target: self, selector: #selector(LoginViewController.unlock), userInfo: nil, repeats: false)

                if disabledView.superview == nil {
                    view.addSubview(disabledView)
                    setNeedsStatusBarAppearanceUpdate()
                    disabledView.constrain(toSuperviewEdges: nil)
                    disabledView.show()
                }
            } else {
                pinPad.view.isUserInteractionEnabled = true
                disabledView.hide { [weak self] in
                    self?.disabledView.removeFromSuperview()
                    self?.setNeedsStatusBarAppearanceUpdate()
                }
            }
        }
    }

    private var isWalletDisabled: Bool {
        guard let walletManager = walletManager else { return false }
        let now = Date().timeIntervalSince1970
        return walletManager.walletDisabledUntil > now
    }

    @objc private func unlock() {
        saveEvent("login.unlocked")
        subheader.pushNewText(S.UnlockScreen.subheader)
        pinPad.view.isUserInteractionEnabled = true
        unlockTimer = nil
        disabledView.hide { [weak self] in
            self?.disabledView.removeFromSuperview()
            self?.setNeedsStatusBarAppearanceUpdate()
        }
    }

    override var preferredStatusBarStyle: UIStatusBarStyle {
        if disabledView.superview == nil {
            return .lightContent
        } else {
            return .default
        }
    }

    required init?(coder aDecoder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }
}
