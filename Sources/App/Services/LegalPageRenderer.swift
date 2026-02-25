import Vapor

/// Generates self-contained HTML pages for legal documents.
/// All CSS is embedded inline — no external dependencies.
struct LegalPageRenderer {

    // MARK: - Privacy Policy

    static func privacyPolicy() -> String {
        return """
        <!DOCTYPE html>
        <html lang="en">
        <head>
            <meta charset="UTF-8">
            <meta name="viewport" content="width=device-width, initial-scale=1.0">
            <title>Snaglist - Privacy Policy</title>
            \(sharedStyles)
        </head>
        <body>
            <div class="legal-page">
                <header class="legal-header">
                    <div class="brand">
                        <div class="brand-mark">S</div>
                        <span class="brand-name">Snaglist</span>
                    </div>
                    <h1>Privacy Policy</h1>
                    <p class="last-updated">Last updated: 25 February 2026</p>
                </header>

                <div class="legal-content">
                    <section>
                        <h2>1. Introduction</h2>
                        <p>Snaglist ("we", "our", "us") operates the Snaglist mobile application and web services. This Privacy Policy explains how we collect, use, and protect your personal information when you use our services.</p>
                        <p>By using Snaglist, you agree to the collection and use of information as described in this policy.</p>
                    </section>

                    <section>
                        <h2>2. Information We Collect</h2>
                        <h3>Account Information</h3>
                        <p>When you sign in with Apple, we receive your Apple User ID and, if you choose to share it, your name and email address. We do not receive or store your Apple ID password.</p>

                        <h3>Project Data</h3>
                        <p>We store the project data you create within Snaglist, including project names, snag descriptions, locations, photos, and completion records. This data is stored securely and is only accessible to you and those you choose to share it with via magic links or team invites.</p>

                        <h3>Photos</h3>
                        <p>Photos you upload to document snags are stored securely on our servers. We do not access, analyse, or share your photos for any purpose other than providing the Snaglist service to you.</p>

                        <h3>Device Information</h3>
                        <p>We may collect device tokens for the purpose of sending push notifications that you have opted into, such as completion approval updates.</p>

                        <h3>Usage Data</h3>
                        <p>We may collect anonymous usage analytics to improve the app experience. This data does not personally identify you.</p>
                    </section>

                    <section>
                        <h2>3. How We Use Your Information</h2>
                        <p>We use the information we collect to:</p>
                        <ul>
                            <li>Provide, maintain, and improve the Snaglist service</li>
                            <li>Authenticate your identity and manage your account</li>
                            <li>Send push notifications you have opted into</li>
                            <li>Generate reports and magic links you request</li>
                            <li>Process subscription payments (via Apple)</li>
                            <li>Respond to support requests</li>
                        </ul>
                    </section>

                    <section>
                        <h2>4. Data Storage and Security</h2>
                        <p>Your data is stored on secure servers hosted by Fly.io. We use industry-standard security measures including encrypted connections (TLS/SSL), secure authentication tokens, and access controls to protect your data.</p>
                        <p>While we take reasonable precautions, no method of electronic storage is 100% secure. We cannot guarantee absolute security of your data.</p>
                    </section>

                    <section>
                        <h2>5. Third-Party Services</h2>
                        <p>Snaglist integrates with the following third-party services:</p>
                        <ul>
                            <li><strong>Apple Sign In</strong> — for secure authentication</li>
                            <li><strong>Apple App Store / RevenueCat</strong> — for subscription payment processing</li>
                            <li><strong>Apple Push Notification Service (APNs)</strong> — for push notifications</li>
                            <li><strong>Fly.io</strong> — for server hosting and data storage</li>
                        </ul>
                        <p>These services have their own privacy policies governing how they handle your data.</p>
                    </section>

                    <section>
                        <h2>6. Data Sharing</h2>
                        <p>We do not sell, trade, or rent your personal information to third parties. We may share data only in the following circumstances:</p>
                        <ul>
                            <li>With contractors or team members you explicitly invite via magic links or team invites</li>
                            <li>When required by law or to comply with legal processes</li>
                            <li>To protect our rights, safety, or property</li>
                        </ul>
                    </section>

                    <section>
                        <h2>7. Data Retention</h2>
                        <p>We retain your data for as long as your account is active or as needed to provide the service. If you wish to delete your account and associated data, please contact us at the email below.</p>
                    </section>

                    <section>
                        <h2>8. Your Rights</h2>
                        <p>You have the right to:</p>
                        <ul>
                            <li>Access the personal data we hold about you</li>
                            <li>Request correction of inaccurate data</li>
                            <li>Request deletion of your data</li>
                            <li>Withdraw consent for data processing</li>
                            <li>Export your project data</li>
                        </ul>
                        <p>To exercise any of these rights, please contact us using the details below.</p>
                    </section>

                    <section>
                        <h2>9. Children's Privacy</h2>
                        <p>Snaglist is not intended for use by children under the age of 16. We do not knowingly collect personal information from children.</p>
                    </section>

                    <section>
                        <h2>10. Changes to This Policy</h2>
                        <p>We may update this Privacy Policy from time to time. We will notify you of significant changes by posting the new policy within the app. Your continued use of Snaglist after changes are posted constitutes acceptance of the updated policy.</p>
                    </section>

                    <section>
                        <h2>11. Contact Us</h2>
                        <p>If you have any questions about this Privacy Policy or your data, please contact us at:</p>
                        <p><a href="mailto:app@snaglist.dev">app@snaglist.dev</a></p>
                    </section>
                </div>

                \(footer)
            </div>
        </body>
        </html>
        """
    }

    // MARK: - Terms of Service

    static func termsOfService() -> String {
        return """
        <!DOCTYPE html>
        <html lang="en">
        <head>
            <meta charset="UTF-8">
            <meta name="viewport" content="width=device-width, initial-scale=1.0">
            <title>Snaglist - Terms of Use</title>
            \(sharedStyles)
        </head>
        <body>
            <div class="legal-page">
                <header class="legal-header">
                    <div class="brand">
                        <div class="brand-mark">S</div>
                        <span class="brand-name">Snaglist</span>
                    </div>
                    <h1>Terms of Use</h1>
                    <p class="last-updated">Last updated: 25 February 2026</p>
                </header>

                <div class="legal-content">
                    <section>
                        <h2>1. Acceptance of Terms</h2>
                        <p>By downloading, installing, or using the Snaglist application ("the App"), you agree to be bound by these Terms of Use. If you do not agree to these terms, do not use the App.</p>
                    </section>

                    <section>
                        <h2>2. Description of Service</h2>
                        <p>Snaglist is a construction snag list and punch list management platform that allows site managers and contractors to track, document, and resolve construction defects. The service includes a mobile application and supporting web services.</p>
                    </section>

                    <section>
                        <h2>3. Subscriptions and Payments</h2>
                        <h3>Free Plan</h3>
                        <p>Snaglist offers a free plan with limited features. Free plan limits are subject to change.</p>

                        <h3>Snaglist Pro Subscription</h3>
                        <p>Snaglist Pro is available as a monthly or annual auto-renewable subscription. The subscription unlocks unlimited projects, snags, photos, and sharing links.</p>

                        <h3>Billing</h3>
                        <p>Payment will be charged to your Apple ID account at confirmation of purchase. Prices are displayed in your local currency within the App and may vary by region.</p>

                        <h3>Auto-Renewal</h3>
                        <p>Your subscription automatically renews unless it is cancelled at least 24 hours before the end of the current billing period. Your account will be charged for renewal within 24 hours prior to the end of the current period at the same rate.</p>

                        <h3>Managing Your Subscription</h3>
                        <p>You can manage and cancel your subscription at any time by going to your account settings in the App Store. Cancellation takes effect at the end of the current billing period — you will continue to have access until then.</p>

                        <h3>Refunds</h3>
                        <p>All purchases are processed by Apple. Refund requests must be made through Apple's support channels in accordance with Apple's refund policies.</p>
                    </section>

                    <section>
                        <h2>4. User Accounts</h2>
                        <p>You may use Snaglist anonymously with limited functionality, or sign in with Apple for the full experience. You are responsible for maintaining the security of your account and for all activity that occurs under your account.</p>
                    </section>

                    <section>
                        <h2>5. User Content</h2>
                        <p>You retain ownership of all content you create within Snaglist, including project data, snag descriptions, and photos. By using the service, you grant us a limited licence to store and process your content solely for the purpose of providing the Snaglist service.</p>
                        <p>You are responsible for ensuring you have the right to upload and share any content you add to the service.</p>
                    </section>

                    <section>
                        <h2>6. Acceptable Use</h2>
                        <p>You agree not to:</p>
                        <ul>
                            <li>Use the service for any unlawful purpose</li>
                            <li>Attempt to gain unauthorised access to the service or its systems</li>
                            <li>Interfere with or disrupt the service</li>
                            <li>Upload malicious content, viruses, or harmful code</li>
                            <li>Use the service to harass, abuse, or harm others</li>
                            <li>Resell or redistribute the service without permission</li>
                        </ul>
                    </section>

                    <section>
                        <h2>7. Magic Links and Sharing</h2>
                        <p>Magic links allow you to share project reports with contractors and team members. You are responsible for managing access to your shared links, including setting PINs and revoking links when appropriate. We are not responsible for unauthorised access resulting from shared links.</p>
                    </section>

                    <section>
                        <h2>8. Availability and Updates</h2>
                        <p>We strive to keep Snaglist available at all times but do not guarantee uninterrupted access. We may update, modify, or discontinue features at any time. We will make reasonable efforts to notify you of significant changes.</p>
                    </section>

                    <section>
                        <h2>9. Limitation of Liability</h2>
                        <p>Snaglist is provided "as is" without warranties of any kind, either express or implied. To the fullest extent permitted by law, we shall not be liable for any indirect, incidental, special, or consequential damages arising from your use of the service.</p>
                        <p>Snaglist is a documentation and tracking tool. It does not replace professional inspection, engineering, or legal advice. You are solely responsible for decisions made based on data within the App.</p>
                    </section>

                    <section>
                        <h2>10. Termination</h2>
                        <p>We reserve the right to suspend or terminate your access to the service at any time for violation of these terms. You may stop using the service at any time by deleting the App and cancelling any active subscriptions.</p>
                    </section>

                    <section>
                        <h2>11. Governing Law</h2>
                        <p>These terms shall be governed by and construed in accordance with the laws of the United Kingdom, without regard to conflict of law provisions.</p>
                    </section>

                    <section>
                        <h2>12. Changes to These Terms</h2>
                        <p>We may update these Terms of Use from time to time. We will notify you of significant changes by posting the new terms within the App. Your continued use of Snaglist after changes are posted constitutes acceptance of the updated terms.</p>
                    </section>

                    <section>
                        <h2>13. Contact Us</h2>
                        <p>If you have any questions about these Terms of Use, please contact us at:</p>
                        <p><a href="mailto:app@snaglist.dev">app@snaglist.dev</a></p>
                    </section>
                </div>

                \(footer)
            </div>
        </body>
        </html>
        """
    }

    // MARK: - Shared Components

    private static var footer: String {
        return """
        <footer class="legal-footer">
            <p>© 2026 Snaglist. All rights reserved.</p>
            <a href="https://apps.apple.com/app/id6758858102" class="footer-cta">Get Snaglist</a>
        </footer>
        """
    }

    private static var sharedStyles: String {
        return """
        <style>
            *, *::before, *::after { margin: 0; padding: 0; box-sizing: border-box; }
            body {
                font-family: -apple-system, BlinkMacSystemFont, 'Segoe UI', Roboto, sans-serif;
                color: #1F2937;
                background: linear-gradient(135deg, #FFF7ED 0%, #F9FAFB 100%);
                min-height: 100vh;
                -webkit-font-smoothing: antialiased;
            }
            .legal-page {
                max-width: 720px;
                margin: 0 auto;
                padding: 24px 16px 48px;
            }
            .legal-header {
                background: #fff;
                border-radius: 16px;
                padding: 32px 24px;
                box-shadow: 0 1px 3px rgba(0,0,0,0.06);
                margin-bottom: 24px;
            }
            .brand {
                display: flex;
                align-items: center;
                gap: 8px;
                margin-bottom: 16px;
            }
            .brand-mark {
                width: 32px; height: 32px;
                background: #F97316; color: #fff;
                border-radius: 8px;
                display: flex; align-items: center; justify-content: center;
                font-weight: 800; font-size: 18px;
            }
            .brand-name {
                font-size: 15px; font-weight: 700; color: #F97316;
            }
            .legal-header h1 {
                font-size: 28px; font-weight: 800; color: #111827; margin-bottom: 4px;
            }
            .last-updated {
                font-size: 13px; color: #9CA3AF;
            }
            .legal-content {
                background: #fff;
                border-radius: 16px;
                padding: 32px 24px;
                box-shadow: 0 1px 3px rgba(0,0,0,0.06);
            }
            .legal-content section {
                margin-bottom: 28px;
            }
            .legal-content section:last-child {
                margin-bottom: 0;
            }
            .legal-content h2 {
                font-size: 18px; font-weight: 700; color: #111827;
                margin-bottom: 12px;
                padding-bottom: 8px;
                border-bottom: 1px solid #F3F4F6;
            }
            .legal-content h3 {
                font-size: 15px; font-weight: 600; color: #374151;
                margin-top: 16px; margin-bottom: 8px;
            }
            .legal-content p {
                font-size: 14px; line-height: 1.7; color: #4B5563;
                margin-bottom: 10px;
            }
            .legal-content ul {
                margin: 8px 0 12px 20px;
                font-size: 14px; line-height: 1.7; color: #4B5563;
            }
            .legal-content li {
                margin-bottom: 4px;
            }
            .legal-content a {
                color: #F97316; text-decoration: none; font-weight: 600;
            }
            .legal-content a:hover {
                text-decoration: underline;
            }
            .legal-footer {
                text-align: center;
                padding: 32px 16px 16px;
                font-size: 13px; color: #9CA3AF;
            }
            .footer-cta {
                display: inline-block; margin-top: 12px;
                color: #F97316; text-decoration: none; font-weight: 600;
                font-size: 14px;
            }
            .footer-cta:hover { text-decoration: underline; }

            @media (max-width: 480px) {
                .legal-page { padding: 12px 10px 40px; }
                .legal-header { padding: 24px 16px; }
                .legal-header h1 { font-size: 24px; }
                .legal-content { padding: 24px 16px; }
            }
        </style>
        """
    }
}
