package org.mayabanque.wero.payment;

import io.quarkus.hibernate.orm.panache.PanacheEntityBase;
import jakarta.persistence.Column;
import jakarta.persistence.Entity;
import jakarta.persistence.EnumType;
import jakarta.persistence.Enumerated;
import jakarta.persistence.Id;
import jakarta.persistence.Table;
import java.time.Instant;

@Entity
@Table(name = "consents")
public class ConsentEntity extends PanacheEntityBase {
    @Id
    @Column(name = "consent_id", nullable = false, length = 80)
    public String consentId;

    @Column(name = "payment_id", nullable = false, unique = true, length = 80)
    public String paymentId;

    @Column(name = "amount_cents", nullable = false)
    public long amountCents;

    @Column(nullable = false, length = 3)
    public String currency;

    @Column(name = "creditor_alias", nullable = false, length = 120)
    public String creditorAlias;

    @Column(name = "subject_id", nullable = false, length = 160)
    public String subjectId;

    @Column(name = "challenge_id", nullable = false, unique = true, length = 80)
    public String challengeId;

    @Enumerated(EnumType.STRING)
    @Column(nullable = false, length = 30)
    public ConsentStatus status;

    @Column(name = "sca_attempts", nullable = false)
    public int scaAttempts;

    @Column(name = "created_at", nullable = false)
    public Instant createdAt;

    @Column(name = "expires_at", nullable = false)
    public Instant expiresAt;

    @Column(name = "authorized_at")
    public Instant authorizedAt;
}
