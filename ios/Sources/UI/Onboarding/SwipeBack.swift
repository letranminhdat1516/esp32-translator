import UIKit

/// The screens hide the navigation bar (`.toolbar(.hidden, for: .navigationBar)`) and draw their own back links,
/// which turns off UIKit's edge swipe back. Re-enable it for every navigation stack that has something to pop
/// (onboarding steps, Settings → Glossary/History/Sharing).
extension UINavigationController: @retroactive UIGestureRecognizerDelegate {
    override open func viewDidLoad() {
        super.viewDidLoad()
        interactivePopGestureRecognizer?.delegate = self
    }

    public func gestureRecognizerShouldBegin(_ gestureRecognizer: UIGestureRecognizer) -> Bool {
        viewControllers.count > 1
    }
}
