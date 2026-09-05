package org.mayabanque.wero.payment;

import jakarta.inject.Inject;
import jakarta.ws.rs.Consumes;
import jakarta.ws.rs.POST;
import jakarta.ws.rs.Path;
import jakarta.ws.rs.Produces;
import jakarta.ws.rs.core.MediaType;
import org.eclipse.microprofile.rest.client.inject.RestClient;

@Path("/payments")
@Consumes(MediaType.APPLICATION_JSON)
@Produces(MediaType.APPLICATION_JSON)
public class PaymentResource {

    @Inject
    @RestClient
    ConsumerPspClient consumerPsp;

    @POST
    @Path("/single-immediate")
    public PaymentResponse create(PaymentRequest request) {
        return consumerPsp.pay(request);
    }

    public record PaymentRequest(String paymentId, long amountCents, String currency, String debtorAlias, String creditorAlias) {}
    public record PaymentResponse(String paymentId, String status, String settlementId) {}
}
