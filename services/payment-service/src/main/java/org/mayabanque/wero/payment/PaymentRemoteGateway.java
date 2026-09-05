package org.mayabanque.wero.payment;

import jakarta.enterprise.context.ApplicationScoped;
import jakarta.inject.Inject;
import jakarta.transaction.Transactional;
import org.eclipse.microprofile.rest.client.inject.RestClient;

/**
 * Isolates outbound HTTP calls from Narayana/JTA transactions.
 *
 * PaymentResource deliberately performs local database work in JTA, but the
 * MicroProfile REST client may use additional executor/Vert.x threads. Carrying
 * an active JTA transaction into those threads causes Narayana to detect the
 * same transaction on multiple threads and can roll back the local JDBC
 * connection. NOT_SUPPORTED suspends the caller transaction for the duration
 * of the remote call and resumes it afterwards.
 */
@ApplicationScoped
public class PaymentRemoteGateway {

    @Inject @RestClient ConsumerPspClient consumerPsp;
    @Inject @RestClient SctInstStatusClient sctInstStatus;

    @Transactional(Transactional.TxType.NOT_SUPPORTED)
    public PaymentResource.PaymentResponse pay(String correlationId, PaymentResource.PaymentRequest request) {
        return consumerPsp.pay(correlationId, request);
    }

    @Transactional(Transactional.TxType.NOT_SUPPORTED)
    public SctInstStatusClient.RailStatus railStatus(String correlationId, String paymentId) {
        return sctInstStatus.get(correlationId, paymentId);
    }
}
