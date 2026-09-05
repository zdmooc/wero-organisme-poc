package org.mayabanque.wero.consumer;

import jakarta.inject.Inject;
import jakarta.ws.rs.Consumes;
import jakarta.ws.rs.POST;
import jakarta.ws.rs.Path;
import jakarta.ws.rs.Produces;
import jakarta.ws.rs.core.MediaType;
import org.eclipse.microprofile.rest.client.inject.RestClient;

@Path("/consumer/payments")
@Consumes(MediaType.APPLICATION_JSON)
@Produces(MediaType.APPLICATION_JSON)
public class ConsumerPaymentResource {
    @Inject
    @RestClient
    WeroClient wero;

    @POST
    public PaymentResponse pay(PaymentRequest request) {
        return wero.forward(request);
    }

    public record PaymentRequest(
            String paymentId,
            long amountCents,
            String currency,
            String debtorAlias,
            String creditorAlias,
            String simulateMode) {}

    public record PaymentResponse(String paymentId, String status, String settlementId) {}
}
